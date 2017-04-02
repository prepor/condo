package api

import (
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
)

type stateManager struct {
	readRequests chan chan<- map[string]instance.Snapshot
}

type clbKeyType string

var clbKey = clbKeyType("api-state-manager")

type newSnapshot struct {
	name     string
	snapshot instance.Snapshot
}

func newStateManager(supervisor *supervisor.Supervisor) *stateManager {
	readRequests := make(chan chan<- map[string]instance.Snapshot)
	instances := make(map[string]instance.Snapshot)
	newInstances := make(chan *instance.Instance)
	removedInstances := make(chan *instance.Instance)
	snapshots := make(chan *newSnapshot)

	supervisor.RegisterNewCallback(clbKey, func(i *instance.Instance) {
		newInstances <- i
	})

	go func() {
		for {
			select {
			case i := <-newInstances:
				instances[i.Name] = &instance.Init{}
				iSnapshots := i.AddSubsriber(clbKey)
				go func() {
					for {
						s, ok := <-iSnapshots
						if ok {
							snapshots <- &newSnapshot{
								name:     i.Name,
								snapshot: s,
							}
						} else {
							removedInstances <- i
							break
						}
					}
				}()
			case i := <-removedInstances:
				delete(instances, i.Name)
			case s := <-snapshots:
				instances[s.name] = s.snapshot
			case r := <-readRequests:
				a := make(map[string]instance.Snapshot)
				for k, v := range instances {
					a[k] = v
				}
				r <- a
			}
		}

	}()

	return &stateManager{
		readRequests: readRequests,
	}
}

func (x *stateManager) readCurrent() map[string]instance.Snapshot {
	a := make(chan map[string]instance.Snapshot)
	x.readRequests <- a
	return <-a
}
