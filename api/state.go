package api

import (
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
)

type stateManager struct {
	readRequests      chan chan<- map[string]instance.Snapshot
	readStreams       chan chan<- *streamAnswer
	closedReadStreams chan chan<- *streamAnswer
}

type clbKeyType string

var clbKey = clbKeyType("api-state-manager")

type newSnapshot struct {
	name     string
	snapshot instance.Snapshot
}

func newStateManager(supervisor *supervisor.Supervisor) *stateManager {
	readRequests := make(chan chan<- map[string]instance.Snapshot)
	readStreams := make(chan chan<- *streamAnswer)
	closedReadStreams := make(chan chan<- *streamAnswer)
	streams := make([]chan<- *streamAnswer, 0)
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
				for _, stream := range streams {
					stream <- &streamAnswer{
						Name:     s.name,
						Snapshot: s.snapshot,
					}
				}
			case r := <-readRequests:
				a := make(map[string]instance.Snapshot)
				for k, v := range instances {
					a[k] = v
				}
				r <- a
			case r := <-readStreams:
				for k, v := range instances {
					r <- &streamAnswer{
						Name:     k,
						Snapshot: v,
					}
				}
				streams = append(streams, r)
			case s := <-closedReadStreams:
				newStreams := streams[:0]
				for _, x := range streams {
					if x != s {
						newStreams = append(newStreams, x)
					} else {
						close(x)
					}
				}
				streams = newStreams
			}
		}

	}()

	return &stateManager{
		readRequests:      readRequests,
		readStreams:       readStreams,
		closedReadStreams: closedReadStreams,
	}
}

func (x *stateManager) readCurrent() map[string]instance.Snapshot {
	a := make(chan map[string]instance.Snapshot)
	x.readRequests <- a
	return <-a
}

type streamAnswer struct {
	Name     string
	Snapshot instance.Snapshot
}

func (x *stateManager) readStream(done <-chan struct{}) <-chan *streamAnswer {
	a := make(chan *streamAnswer)
	x.readStreams <- a
	go func() {
		<-done
		x.closedReadStreams <- a
	}()
	return a
}
