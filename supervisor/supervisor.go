package supervisor

import (
	"sync"

	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/system"
)

type Supervisor struct {
	system          *system.System
	instances       map[string]*instance.Instance
	group           *sync.WaitGroup
	done            chan struct{}
	newCallbacks    map[interface{}]func(*instance.Instance)
	removeCallbacks map[interface{}]func(*instance.Instance)
}

func New(system *system.System) *Supervisor {
	return &Supervisor{
		system:          system,
		instances:       make(map[string]*instance.Instance),
		group:           &sync.WaitGroup{},
		done:            make(chan struct{}),
		newCallbacks:    make(map[interface{}]func(*instance.Instance)),
		removeCallbacks: make(map[interface{}]func(*instance.Instance)),
	}
}

func (x *Supervisor) RegisterNewCallback(k interface{}, clb func(*instance.Instance)) {
	x.newCallbacks[k] = clb
}

func (x *Supervisor) DegisterNewCallback(k interface{}) {
	delete(x.newCallbacks, k)
}

func (x *Supervisor) RegisterRemoveCallback(k interface{}, clb func(*instance.Instance)) {
	x.removeCallbacks[k] = clb
}

func (x *Supervisor) DegisterRemoveCallback(k interface{}) {
	delete(x.removeCallbacks, k)
}

func (x *Supervisor) Start() {
	events := x.system.Specs.WatchSpecs(x.done)
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
				for _, v := range x.newCallbacks {
					v(instance)
				}
				instance.Start()
			case system.RemovedSpec:
				instance := x.instances[e.SpecName()]
				instance.Stop()
				for _, v := range x.removeCallbacks {
					v(instance)
				}
				delete(x.instances, e.SpecName())
			}
		}
	}()
}

func (x *Supervisor) Stop() {
	close(x.done)
	x.group.Wait()
	for _, v := range x.instances {
		v.Stop()
	}
}
