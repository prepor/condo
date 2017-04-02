package instance

import (
	"sync"

	"github.com/Sirupsen/logrus"
	log "github.com/Sirupsen/logrus"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/system"
)

type Instance struct {
	Name             string
	Snapshot         Snapshot
	system           *system.System
	logger           *logrus.Entry
	events           chan event
	eventsLoopDone   chan struct{}
	done             chan struct{}
	group            *sync.WaitGroup
	subscribers      map[interface{}]chan<- Snapshot
	subscribersMutex sync.Mutex
}

func New(system *system.System, name string) *Instance {
	logger := log.WithField("instance", name)
	return &Instance{
		Name:             name,
		Snapshot:         &Init{},
		system:           system,
		logger:           logger,
		events:           make(chan event, 1),
		eventsLoopDone:   make(chan struct{}),
		subscribers:      make(map[interface{}]chan<- Snapshot),
		subscribersMutex: sync.Mutex{},
		done:             make(chan struct{}),
		group:            &sync.WaitGroup{},
	}
}

func (x *Instance) Start() {
	newSpecs := x.system.Specs.ReceiveSpecs(x.Name, x.done)
	go func() {
		x.group.Add(1)
		defer x.group.Done()

		var (
			s  *spec.Spec
			ok bool
		)
		for {
			s, ok = <-newSpecs
			if ok {
				select {
				case x.events <- eventNewSpec{spec: s}:
				case <-x.done:
					break
				}

			} else {
				break
			}
		}
	}()
	go func() {
		defer close(x.eventsLoopDone)
		var (
			e  event
			ok bool
		)
		for {
			e, ok = <-x.events
			if ok {
				x.logger.WithField("event", e).Info("New event")
				newSnapshot := x.Snapshot.apply(x, e)
				if newSnapshot != x.Snapshot {
					x.Snapshot = newSnapshot
					x.logger.WithField("state", x.Snapshot).Info("Updated state")
					x.subscribersMutex.Lock()
					for _, subscription := range x.subscribers {
						subscription <- x.Snapshot
					}
					x.subscribersMutex.Unlock()
				}
			} else {
				x.subscribersMutex.Lock()
				for _, subscription := range x.subscribers {
					close(subscription)
				}
				x.subscribersMutex.Unlock()
				break
			}
		}
	}()
}

func (x *Instance) Stop() {
	x.events <- eventStop{}
	close(x.done)
	x.group.Wait()
	close(x.events)
	<-x.eventsLoopDone
}

func (x *Instance) AddSubsriber(k interface{}) <-chan Snapshot {
	x.subscribersMutex.Lock()
	defer x.subscribersMutex.Unlock()

	ch := make(chan Snapshot)
	x.subscribers[k] = ch
	return ch
}

func (x *Instance) RemoveSubscriber(k interface{}) {
	x.subscribersMutex.Lock()
	defer x.subscribersMutex.Unlock()

	delete(x.subscribers, k)
}
