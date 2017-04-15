package api

import (
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
)

type stateManager struct {
	readRequests      chan chan<- state
	readStreams       chan chan<- state
	closedReadStreams chan chan<- state
}

type subscriptionKeyType string

var subscriptionKey = subscriptionKeyType("api-state-manager")

type newSnapshot struct {
	name     string
	snapshot instance.Snapshot
}

type state map[string]instance.Snapshot

func newStateManager(supervisor *supervisor.Supervisor) *stateManager {
	readRequests := make(chan chan<- state)
	readStreams := make(chan chan<- state)
	closedReadStreams := make(chan chan<- state)
	streams := make([]chan<- state, 0)
	instances := make(state)
	newInstances := supervisor.Subscribe(subscriptionKey)
	removedInstances := make(chan *instance.Instance)
	snapshots := make(chan *newSnapshot)

	copyState := func() state {
		s2 := make(state)
		for k, v := range instances {
			s2[k] = v
		}
		return s2
	}

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
				for _, stream := range streams {
					stream <- copyState()
				}
			case s := <-snapshots:
				instances[s.name] = s.snapshot
				for _, stream := range streams {
					stream <- copyState()
				}
			case r := <-readRequests:
				a := make(map[string]instance.Snapshot)
				for k, v := range instances {
					a[k] = v
				}
				r <- a
			case r := <-readStreams:
				r <- copyState()
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

func (x *stateManager) readCurrent() state {
	a := make(chan state)
	x.readRequests <- a
	return <-a
}

func (x *stateManager) readStream(done <-chan struct{}) <-chan state {
	a := make(chan state)
	x.readStreams <- a
	go func() {
		<-done
		x.closedReadStreams <- a
	}()
	return a
}
