package supervisor

import (
	"sync"

	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/system"
)

type Supervisor struct {
	system             *system.System
	instances          map[string]*instance.Instance
	group              *sync.WaitGroup
	subscriptions      map[interface{}]chan<- *instance.Instance
	subscriptionsMutex sync.Mutex
}

func New(system *system.System) *Supervisor {
	return &Supervisor{
		system:             system,
		instances:          make(map[string]*instance.Instance),
		group:              &sync.WaitGroup{},
		subscriptions:      make(map[interface{}]chan<- *instance.Instance),
		subscriptionsMutex: sync.Mutex{},
	}
}

func (x *Supervisor) Start() {
	go x.worker()
	go func() {
		x.system.Components.Add(1)
		defer x.system.Components.Done()
		<-x.system.Done
		x.group.Wait()
		for _, v := range x.instances {
			v.Stop()
		}
	}()
}

func (x *Supervisor) Subscribe(k interface{}) <-chan *instance.Instance {
	x.subscriptionsMutex.Lock()
	defer x.subscriptionsMutex.Unlock()
	ch := make(chan *instance.Instance)
	x.subscriptions[k] = ch
	return ch
}

func (x *Supervisor) Unsubscribe(k interface{}) {
	x.subscriptionsMutex.Lock()
	defer x.subscriptionsMutex.Unlock()
	delete(x.subscriptions, k)
}

func (x *Supervisor) worker() {
	events := x.system.Specs.WatchSpecs(x.system.Done)
	x.group.Add(1)
	go func() {
		defer x.group.Done()
		for {
			e, ok := <-events
			if !ok {
				break
			}

			switch e := e.(type) {
			case system.NewSpec:
				instance := instance.New(x.system, e.SpecName())
				x.instances[e.SpecName()] = instance
				x.subscriptionsMutex.Lock()
				for _, v := range x.subscriptions {
					v <- instance
				}
				x.subscriptionsMutex.Unlock()
				instance.Start()
			case system.RemovedSpec:
				instance := x.instances[e.SpecName()]
				instance.Stop()
				delete(x.instances, e.SpecName())
			}
		}
		for _, v := range x.subscriptions {
			close(v)
		}
	}()
}
