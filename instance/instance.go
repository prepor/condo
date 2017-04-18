package instance

import (
	"sync"

	"github.com/Sirupsen/logrus"
	log "github.com/Sirupsen/logrus"
	"github.com/prepor/condo/proxy"
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
	proxy            *proxy.InstanceProxy
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
	x.group.Add(1)
	go func() {
		defer x.group.Done()

		var (
			s  *spec.Spec
			ok bool
		)
	Loop:
		for {
			s, ok = <-newSpecs
			if ok {
				select {
				case x.events <- eventNewSpec{spec: s}:
				case <-x.done:
					break Loop
				}

			} else {
				break
			}
		}
	}()
	go func() {
		defer close(x.eventsLoopDone)
		var (
			e event
		)
		for {
			e = <-x.events
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

			if _, ok := newSnapshot.(*Stopped); ok {
				x.subscribersMutex.Lock()
				for _, subscription := range x.subscribers {
					close(subscription)
				}
				x.subscribersMutex.Unlock()
				go func() {
					for {
						_, ok := <-x.events
						if !ok {
							break
						}
					}
				}()
				x.group.Wait()
				close(x.events)
				break
			}
		}
	}()
}

func (x *Instance) Stop() {
	x.events <- eventStop{}
	close(x.done)
	<-x.eventsLoopDone
}

func (x *Instance) Subsribe(k interface{}) <-chan Snapshot {
	x.subscribersMutex.Lock()
	defer x.subscribersMutex.Unlock()

	ch := make(chan Snapshot)
	x.subscribers[k] = ch
	return ch
}

func (x *Instance) Unsubscribe(k interface{}) {
	x.subscribersMutex.Lock()
	defer x.subscribersMutex.Unlock()

	delete(x.subscribers, k)
}

func (x *Instance) ensureProxy(container *Container) error {
	if x.proxy == nil && container.Container.Spec.Proxy == nil {
		return nil
	}
	if x.proxy == nil {
		p, err := x.system.Proxy.NewInstanceProxy(x.logger, container.Container)
		if err != nil {
			return err
		}
		x.proxy = p
	} else {
		if container.Container.Spec.Proxy == nil {
			x.proxy.Stop()
			x.proxy = nil
			return nil
		}
		err := x.proxy.SetBackend(container.Container)
		if err != nil {
			return err
		}
	}

	return nil
}

func (x *Instance) ensureStoppedProxy() {
	if x.proxy != nil {
		x.proxy.Stop()
		x.proxy = nil
	}
}
