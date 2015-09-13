// condo project condo.go
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"reflect"
	"text/template"
	"time"
)

type Consul struct {
	AgentEndpoint string
	HTTPClient    *http.Client
}

type ImageSpec struct {
	Name string
	Tag  string
	Id   string
}

type VolumeSpec struct {
	From string
	To   string
}

type EnvSpec struct {
	Name  string
	Value string
}

type CheckSpec struct {
	Script   string
	Interval string
	Timeout  uint
}

type ServiceSpec struct {
	Name     string
	Check    *CheckSpec `json:",omitempty"`
	Port     uint
	HostPort uint
	Udp      bool
	Tags     []string
}

type DiscoverySpec struct {
	Service  string
	Tag      string
	Multiple bool
	Env      string
}

type LogsSpec struct {
	Type   string
	Config map[string]string
}

type Spec struct {
	Image            ImageSpec
	Services         []ServiceSpec
	Volumes          []VolumeSpec
	Cmd              []string
	Envs             []EnvSpec
	Discoveries      []DiscoverySpec
	Name             string
	Host             string
	NetworkMode      string
	User             string
	Privileged       bool
	StopBefore       bool
	StopAfterTimeout uint
	KillTimeout      uint
	Logs             *LogsSpec
	ModifyIndex      uint
}

func NewConsul(consulAgentEndpoint string) *Consul {
	return &Consul{
		AgentEndpoint: consulAgentEndpoint,
		HTTPClient:    http.DefaultClient,
	}
}

type consulKey struct {
	CreateIndex uint
	ModifyIndex uint
	LockIndex   uint
	Flags       uint
	Key         string
	Value       []byte
}

type consulKeys []consulKey

type registerServiceCmdCheck struct {
	Script   string
	Interval string
}
type registerServiceCmd struct {
	ID    string
	Name  string
	Tags  []string
	Port  uint
	Check *registerServiceCmdCheck `json:",omitempty"`
}

type checkerEnv struct {
	ID         string
	Port       uint
	DockerHost string
}

func checkerScript(env *checkerEnv, script string) (string, error) {
	// docker exec leaks now https://github.com/docker/docker/issues/12899
	// return fmt.Sprintf("docker exec %s %s", id, script)
	tmpl, err := template.New("checker script").Parse(script)
	if err != nil {
		return "", err
	}
	result := new(bytes.Buffer)
	err = tmpl.Execute(result, env)
	if err != nil {
		return "", err
	}
	return result.String(), nil
}

func (consul *Consul) RegisterService(serviceId string, service *ServiceSpec, port uint, host string) error {
	url := consul.AgentEndpoint + "/v1/agent/service/register"

	fmt.Printf("Consul service %s register: %s\n", service.Name, url)
	checker, err := checkerScript(&checkerEnv{ID: serviceId, Port: port, DockerHost: host}, service.Check.Script)
	if err != nil {
		return err
	}
	body, err := json.Marshal(&registerServiceCmd{
		ID:   service.Name + "_" + serviceId,
		Name: service.Name,
		Tags: service.Tags,
		Port: port,
		Check: &registerServiceCmdCheck{
			Script:   checker,
			Interval: service.Check.Interval}})

	if err != nil {
		return err
	}
	req, err := http.NewRequest("PUT", url, bytes.NewBuffer(body))
	if err != nil {
		return err
	}
	// req.Header.Set("Content-Type", "application/json")
	resp, err := consul.HTTPClient.Do(req)
	if err != nil {
		return err
	} else if resp.StatusCode != 200 {
		v, _ := ioutil.ReadAll(resp.Body)
		defer resp.Body.Close()
		return errors.New(fmt.Sprintf("service registering: bad http-status %s; %s", resp.StatusCode, v))
	}
	defer resp.Body.Close()
	fmt.Printf("Consul service %s(%s) registered\n", service.Name, serviceId)
	return nil
}

func (consul *Consul) DeregisterService(idSuffix string, service *ServiceSpec) error {
	url := consul.AgentEndpoint + fmt.Sprintf("/v1/agent/service/deregister/%s", service.Name+"_"+idSuffix)

	fmt.Printf("Consul service %s(%s) deregister: %s\n", service.Name, idSuffix, url)

	req, err := http.NewRequest("DELETE", url, nil)
	if err != nil {
		return err
	}
	resp, err := consul.HTTPClient.Do(req)
	if err != nil {
		return err
	} else if resp.StatusCode != 200 {
		defer resp.Body.Close()
		v, _ := ioutil.ReadAll(resp.Body)
		return errors.New(fmt.Sprintf("service registering: bad http-status %s; %s", resp.StatusCode, v))
	}
	defer resp.Body.Close()
	fmt.Printf("Consul service %s(%s) deregistered!\n", service.Name, idSuffix)
	return nil
}

func (consul *Consul) ReceiveSpec(consulKey string, index uint) (*Spec, error) {
	url := consul.AgentEndpoint + "/v1/kv/" + consulKey
	if index > 0 {
		url += fmt.Sprintf("?wait=10s&index=%d", index)
	}
	resp, err := consul.HTTPClient.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, errors.New(fmt.Sprintf("Bad response: %+v\n", resp))
	}

	var keys consulKeys
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	err = json.Unmarshal(body, &keys)
	if err != nil {
		return nil, err
	}
	key := keys[0]

	var spec Spec
	err = json.Unmarshal(key.Value, &spec)
	if err != nil {
		return nil, err
	}
	spec.ModifyIndex = key.ModifyIndex
	return &spec, nil
}

func (consul *Consul) ReceiveSpecCh(consulKey string, index uint) chan *Spec {
	ch := make(chan *Spec)
	go func() {
		v, err := consul.ReceiveSpec(consulKey, index)
		if err != nil {
			fmt.Printf("Error in ReceiveSpecCh: %s\n", err)
		} else {
			ch <- v
		}
		close(ch)
	}()
	return ch
}

type CheckResp struct {
	Node        string
	CheckID     string
	Name        string
	Status      string
	ServiceID   string
	ServiceName string
}

type checksResp map[string]*CheckResp

func (consul *Consul) ReceiveCheck(id string) (*CheckResp, error) {
	// is this should be Catalog request?
	url := consul.AgentEndpoint + "/v1/agent/checks"
	resp, err := consul.HTTPClient.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)

	if resp.StatusCode != 200 {
		return nil, errors.New(fmt.Sprintf("Bad response: %d %s\n", resp.StatusCode, body))
	}

	if err != nil {
		return nil, err
	}
	var checks checksResp
	err = json.Unmarshal(body, &checks)
	if err != nil {
		return nil, err
	}
	check := checks[id]
	if check == nil {
		return nil, errors.New(fmt.Sprintf("Undefined check: %s %s\n", id, body))
	} else {
		return check, nil
	}
}

type DiscoveredService struct {
	Node    string
	Address string
	Port    uint
}

type serviceDiscoveryRespNode struct {
	Node    string
	Address string
}

type serviceDiscoveryRespService struct {
	Port uint
}

type serviceDiscoveryRespOne struct {
	Node    serviceDiscoveryRespNode
	Service serviceDiscoveryRespService
}

type serviceDiscoveryResp []serviceDiscoveryRespOne

func serviceDiscoveryTick(consul *Consul, url string, index string) ([]*DiscoveredService, string, error) {
	if index != "" {
		url += "&wait=30s&index=" + index
	}
	fmt.Printf("Consul discovering services: %s\n", url)
	resp, err := consul.HTTPClient.Get(url)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)

	if resp.StatusCode != 200 {
		return nil, "", errors.New(fmt.Sprintf("Bad response: %d %s\n", resp.StatusCode, body))
	}

	if err != nil {
		return nil, "", err
	}
	var discovered serviceDiscoveryResp
	err = json.Unmarshal(body, &discovered)
	if err != nil {
		return nil, "", err
	}
	res := make([]*DiscoveredService, len(discovered))
	for i, v := range discovered {
		res[i] = &DiscoveredService{
			Node:    v.Node.Node,
			Address: v.Node.Address,
			Port:    v.Service.Port,
		}
	}
	fmt.Printf("Consul discovered services: %s\n", string(body))
	return res, resp.Header["X-Consul-Index"][0], nil
}

func (consul *Consul) ServiceDiscovery(service string, tag string, passing bool, done chan bool) chan []*DiscoveredService {
	url := consul.AgentEndpoint + "/v1/health/service/" + service + "?"
	if tag != "" {
		url += "&tag=" + tag
	}
	if passing {
		url += "&passing"
	}

	out := make(chan []*DiscoveredService)
	go func() {
		var index string
		var lastDiscovered []*DiscoveredService
		for true {
			v, i, err := serviceDiscoveryTick(consul, url, index)
			index = i

			select {
			case <-done:
				close(out)
				return
			default:
				if err != nil {
					fmt.Println("Service discovery error: ", err)
					time.Sleep(time.Millisecond * 100)
				} else if !reflect.DeepEqual(lastDiscovered, v) {
					out <- v
					lastDiscovered = v
				}
			}
		}
	}()
	return out
}

func (consul *Consul) WaitHealth(serviceId string, service *ServiceSpec) error {
	timer := time.NewTimer(time.Millisecond * time.Duration(service.Check.Timeout))
	for true {
		select {
		case <-timer.C:
			return errors.New(fmt.Sprintf("WaitHealth timeout: %+v", service))
		default:
			check, err := consul.ReceiveCheck(fmt.Sprintf("service:%s_%s", service.Name, serviceId))
			if err != nil {
				return nil
			} else if check.Status == "passing" {
				return nil
			} else {
				time.Sleep(time.Millisecond * 1000)
			}
		}
	}
	return nil
}
