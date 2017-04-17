package expose

import (
	"sync"

	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"
)

type Instance struct {
	Condo    string
	Service  string
	Snapshot interface{}
}

type Exposer interface {
	SaveState(instance *Instance)
	ReceiveStates(done <-chan struct{}) <-chan []*Instance
}

type subscriptionKeyType string

var subscriptionKey = subscriptionKeyType("exposer-worker")

type Self struct {
	system     *system.System
	supervisor *supervisor.Supervisor
	exposer    Exposer
	condo      string
	watchers   sync.WaitGroup
}

func New(system *system.System, supervisor *supervisor.Supervisor, exposer Exposer) *Self {
	instances := supervisor.Subscribe(subscriptionKey)

	system.Components.Add(1)
	self := &Self{
		system:     system,
		supervisor: supervisor,
		exposer:    exposer,
		condo:      system.Name(),
		watchers:   sync.WaitGroup{},
	}
	go func() {
		defer system.Components.Done()
	Loop:
		for {
			select {
			case i, ok := <-instances:
				if !ok {
					break Loop
				}
				self.watchers.Add(1)
				go self.instanceWatcher(i)
			}

		}
		self.watchers.Wait()
	}()
	return self
}

func (x *Self) instanceWatcher(i *instance.Instance) {
	defer x.watchers.Done()
	snapshots := i.Subsribe(subscriptionKey)
	for {
		s, ok := <-snapshots
		if !ok {
			break
		}
		x.exposer.SaveState(&Instance{
			Condo:    x.condo,
			Service:  i.Name,
			Snapshot: s,
		})
	}
}
