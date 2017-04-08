package api

import (
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
)

type stateManager struct {
	readRequests      chan chan<- map[string]instance.Snapshot
	readStreams       chan chan<- *StreamAnswer
	closedReadStreams chan chan<- *StreamAnswer
}

type subscriptionKeyType string

var subscriptionKey = subscriptionKeyType("api-state-manager")

type newSnapshot struct {
	name     string
	snapshot instance.Snapshot
}

func newStateManager(supervisor *supervisor.Supervisor) *stateManager {
	readRequests := make(chan chan<- map[string]instance.Snapshot)
	readStreams := make(chan chan<- *StreamAnswer)
	closedReadStreams := make(chan chan<- *StreamAnswer)
	streams := make([]chan<- *StreamAnswer, 0)
	instances := make(map[string]instance.Snapshot)
	newInstances := supervisor.Subscribe(subscriptionKey)
	removedInstances := make(chan *instance.Instance)
	snapshots := make(chan *newSnapshot)

	go func() {
		for {
			select {
			case i, ok := <-newInstances:
				if !ok {
					// FIXME should provide graceful stop if
					// we stop loop here it stops listen
					// snapshots and removedInstances and
					// blocks app
					break
				}
				instances[i.Name] = &instance.Init{}
				iSnapshots := i.Subsribe(subscriptionKey)
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
					stream <- &StreamAnswer{
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
					r <- &StreamAnswer{
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

type StreamAnswer struct {
	Name     string
	Snapshot instance.Snapshot
}

func (x *stateManager) readStream(done <-chan struct{}) <-chan *StreamAnswer {
	a := make(chan *StreamAnswer)
	x.readStreams <- a
	go func() {
		<-done
		x.closedReadStreams <- a
	}()
	return a
}
