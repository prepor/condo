// condo project condo.go
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"reflect"
	"strings"
	"syscall"
	"time"
)

type Deps struct {
	Docker *Docker
	Consul *Consul
}

func endpoint(key string) string {
	endpoint := os.Getenv(key)
	if endpoint == "" {
		panic(fmt.Sprintf("Don't know endpoint. Set %s environment key", key))
	}
	return endpoint
}

func registerServices(consul *Consul, container *Container) error {
	for _, s := range container.Spec.Services {
		err := consul.RegisterService(container.Id, &s, container.PortsMapping[s.Port])
		if err != nil {
			fmt.Println("Error while service registering:", err)
			return err
		}
	}
	return nil
}

func waitServices(consul *Consul, container *Container) error {
	for _, s := range container.Spec.Services {
		err := consul.WaitHealth(container.Id, &s)
		if err != nil {
			fmt.Printf("Error while waiting for service %s: %s\n", &s.Name, err)
			return err
		}
	}
	return nil
}

func deregisterServices(consul *Consul, container *Container) error {
	for _, s := range container.Spec.Services {
		err := consul.DeregisterService(container.Id, &s)
		if err != nil {
			fmt.Printf("Can't deregister service %s: %s\n", &s.Name, err)
			return err
		}
	}
	return nil
}

func deploySpec(deps *Deps, currentContainer *Container, newSpec *Spec) (*Container, error) {
	var err error
	if newSpec.StopBefore && currentContainer != nil {
		err = deregisterServices(deps.Consul, currentContainer)
		if err != nil {
			return nil, err
		}
		err = deps.Docker.StopContainer(currentContainer)
		if err != nil {
			return nil, err
		}
	}
	newContainer, err := deps.Docker.DeployContainer(newSpec)
	if err != nil {
		return nil, err
	}

	haltContainer := func() {
		err2 := deps.Docker.StopContainer(newContainer)
		if err2 != nil {
			fmt.Printf("Can't stop container: %s (%s)", err2, newContainer.Id)
		}
	}
	err = registerServices(deps.Consul, newContainer)
	if err != nil {
		haltContainer()
		return nil, err
	}
	haltServices := func(container *Container) {
		err = deregisterServices(deps.Consul, container)
		if err != nil {
			fmt.Printf("Can't deregister container: %s (%s)\n", err, currentContainer.Id)
		}
	}
	err = waitServices(deps.Consul, newContainer)
	if err != nil {
		haltServices(newContainer)
		haltContainer()
		return nil, err
	}
	if !newSpec.StopBefore && currentContainer != nil {
		haltServices(currentContainer)
		time.Sleep(time.Duration(newSpec.StopAfterTimeout) * time.Second)
		err = deps.Docker.StopContainer(currentContainer)
		if err != nil {
			fmt.Printf("Can't stop container: %s (%s)\n", err, currentContainer.Id)
		}
	}
	return newContainer, nil
}

func deployerLoop(deps *Deps, input chan *Spec, exit chan bool) {
	var currentContainer *Container
	var err error
	newSpec := <-input
	for true {
		if newSpec == nil {
			if currentContainer != nil {
				err = deps.Docker.StopContainer(currentContainer)
				if err != nil {
					fmt.Printf("Can't stop container: %s (%s)\n", err, currentContainer.Id)
				}

				err = deregisterServices(deps.Consul, currentContainer)
				if err != nil {
					fmt.Printf("Can't deregister container: %s (%s)\n", err, currentContainer.Id)
				}
			}
			close(exit)
			return
		} else {
			var newContainer *Container
			newContainer, err = deploySpec(deps, currentContainer, newSpec)
			if err != nil {
				fmt.Println("Error while deploying spec:", err)
				t := time.NewTimer(time.Second * 5)
				select {
				case newSpec = <-input:
				case <-t.C: // we will retry
				}
			} else {
				currentContainer = newContainer
				newSpec = <-input
				fmt.Println("New spec received")
			}
		}
	}
}

func startDeployer(deps *Deps, input chan *Spec) chan bool {
	exit := make(chan bool)
	go deployerLoop(deps, input, exit)
	return exit
}

// start watching for every spcified service. wait for discovering of all services. then
// produce spec with updated environments. after that continue watching and produce new
// spec on every change
func watchForSpecServices(consul *Consul, specForWatch *Spec, out chan *Spec, done chan bool) {
	serviceChans := make([]chan []*DiscoveredService, len(specForWatch.Discoveries))
	updatedSpec := &*specForWatch
	for i, v := range specForWatch.Discoveries {
		serviceChans[i] = consul.ServiceDiscovery(v.Service, v.Tag, true, done)
	}
	cases := make([]reflect.SelectCase, len(serviceChans))
	receivedDiscoveries := make(map[DiscoverySpec]bool)

	for i, ch := range serviceChans {
		cases[i] = reflect.SelectCase{
			Dir:  reflect.SelectRecv,
			Chan: reflect.ValueOf(ch)}
	}
	discoveries := specForWatch.Discoveries
	for true {
		chosen, value, ok := reflect.Select(cases)
		if ok {
			discovered := discoveries[chosen]
			value2 := value.Interface().([]*DiscoveredService)
			var envValue string
			if len(value2) == 0 {
				continue
			} else if discovered.Multiple {
				valueStrings := make([]string, len(value2))
				for i, v := range value2 {
					valueStrings[i] = fmt.Sprintf("%s:%d", v.Address, v.Port)
				}
				envValue = strings.Join(valueStrings, ",")
			} else {
				envValue = fmt.Sprintf("%s:%d", value2[0].Address, value2[0].Port)
			}
			existsEnv := -1
			for i, v := range updatedSpec.Envs {
				if v.Name == discovered.Env {
					existsEnv = i
					break
				}
			}
			env := EnvSpec{
				Name:  discovered.Env,
				Value: envValue}
			if existsEnv != -1 {
				updatedSpec.Envs[existsEnv] = env
			} else {
				updatedSpec.Envs = append(updatedSpec.Envs, env)
			}
			receivedDiscoveries[discovered] = true
			if len(receivedDiscoveries) >= len(specForWatch.Discoveries) {
				select {
				case <-done:
				case out <- updatedSpec:
				}
			}

		} else if len(cases) > 1 {
			cases = append(cases[:chosen], cases[chosen+1:]...)
			discoveries = append(discoveries[:chosen], discoveries[chosen+1:]...)
		} else {
			return
		}
	}
}

func startServiceDiscovery(deps *Deps, input chan *Spec) chan *Spec {
	out := make(chan *Spec)
	go func() {
		var currentWatcher chan bool
		for true {
			newSpec := <-input
			if newSpec == nil {
				if currentWatcher != nil {
					close(currentWatcher)
				}
				close(out)
				return
			} else if len(newSpec.Discoveries) == 0 {
				out <- newSpec
			} else {
				if currentWatcher != nil {
					close(currentWatcher)
				}
				currentWatcher = make(chan bool)
				go watchForSpecServices(deps.Consul, newSpec, out, currentWatcher)
			}
		}
	}()
	return out
}

func listenerLoop(deps *Deps, key string, out chan *Spec, doneCh chan bool) {
	var lastIndex uint
	for true {
		newSpecCh := deps.Consul.ReceiveSpecCh(key, lastIndex)
		select {
		case newSpec := <-newSpecCh:
			if newSpec != nil && lastIndex != newSpec.ModifyIndex {
				// Should not get error here, ignore
				specJson, _ := json.Marshal(newSpec)
				fmt.Printf("New spec received: %s\n", specJson)
				select {
				case out <- newSpec:
				default:
					<-out
					out <- newSpec
				}
				lastIndex = newSpec.ModifyIndex
			} else {
				time.Sleep(5 * time.Second)
			}
		case <-doneCh:
			close(out)
			return
		}
	}
}

func startListener(deps *Deps, key string, doneCh chan bool) chan *Spec {
	out := make(chan *Spec, 1)
	go listenerLoop(deps, key, out, doneCh)
	return out
}

func main() {
	deps := &Deps{
		Docker: NewDocker(endpoint("DOCKER")),
		Consul: NewConsul(endpoint("CONSUL_AGENT"))}

	consulKey := os.Args[1]
	fmt.Println("Running docker image described in", consulKey)

	sigs := make(chan os.Signal, 1)
	done := make(chan bool, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigs
		fmt.Println()
		fmt.Println(sig)
		done <- true
	}()

	newImages := startListener(deps, consulKey, done)
	withServices := startServiceDiscovery(deps, newImages)
	waiter := startDeployer(deps, withServices)

	<-waiter
}
