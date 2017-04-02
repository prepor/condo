package supervisor

import (
	"sync"

	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/system"
)

type Supervisor struct {
	system            *system.System
	instances         map[string]*instance.Instance
	group             *sync.WaitGroup
	newCallbacks      map[interface{}]func(*instance.Instance)
	newCallbacksMutex sync.Mutex
}

func New(system *system.System) *Supervisor {
	return &Supervisor{
		system:            system,
		instances:         make(map[string]*instance.Instance),
		group:             &sync.WaitGroup{},
		newCallbacks:      make(map[interface{}]func(*instance.Instance)),
		newCallbacksMutex: sync.Mutex{},
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

func (x *Supervisor) RegisterNewCallback(k interface{}, clb func(*instance.Instance)) {
	x.newCallbacksMutex.Lock()
	defer x.newCallbacksMutex.Unlock()
	x.newCallbacks[k] = clb
}

func (x *Supervisor) DegisterNewCallback(k interface{}) {
	x.newCallbacksMutex.Lock()
	defer x.newCallbacksMutex.Unlock()
	delete(x.newCallbacks, k)
}

func (x *Supervisor) worker() {
	events := x.system.Specs.WatchSpecs(x.system.Done)
	go func() {
		x.group.Add(1)
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
				x.newCallbacksMutex.Lock()
				for _, v := range x.newCallbacks {
					v(instance)
				}
				x.newCallbacksMutex.Unlock()
				instance.Start()
			case system.RemovedSpec:
				instance := x.instances[e.SpecName()]
				instance.Stop()
				delete(x.instances, e.SpecName())
			}
		}
	}()
}
