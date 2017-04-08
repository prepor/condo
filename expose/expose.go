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
	ReceiveStates(revision int) ([]*Instance, error)
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

type watcherKeyType string

var watcherKey = watcherKeyType("exposer-watcher")

func (x *Self) instanceWatcher(i *instance.Instance) {
	defer x.watchers.Done()
	snapshots := i.Subsribe(watcherKey)
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

func (x *Self) Receive(revision int) ([]*Instance, error) {
	return x.exposer.ReceiveStates(revision)
}
