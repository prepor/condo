package instance

import (
	"fmt"
	"sync"
	"time"

	"github.com/Sirupsen/logrus"
	log "github.com/Sirupsen/logrus"
	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/system"
	uuid "github.com/satori/go.uuid"
)

type Instance struct {
	Name           string
	Snapshot       Snapshot
	system         *system.System
	logger         *logrus.Entry
	events         chan event
	eventsLoopDone chan struct{}
	done           chan struct{}
	group          *sync.WaitGroup
	subscribers    map[interface{}]chan<- Snapshot
}

func New(system *system.System, name string) *Instance {
	logger := log.WithField("instance", name)
	return &Instance{
		Name:           name,
		Snapshot:       &Init{},
		system:         system,
		logger:         logger,
		events:         make(chan event, 1),
		eventsLoopDone: make(chan struct{}),
		subscribers:    make(map[interface{}]chan<- Snapshot),
		done:           make(chan struct{}),
		group:          &sync.WaitGroup{},
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
					for _, subscription := range x.subscribers {
						subscription <- x.Snapshot
					}
				}
			} else {
				for _, subscription := range x.subscribers {
					close(subscription)
				}
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
	ch := make(chan Snapshot)
	x.subscribers[k] = ch
	return ch
}

func (x *Instance) RemoveSubscriber(k interface{}) {
	delete(x.subscribers, k)
}

type event interface {
	fmt.Stringer
	event()
}

type eventNewSpec struct {
	spec *spec.Spec
}

func (n eventNewSpec) event() {}

func (n eventNewSpec) String() string {
	return "NewSpec"
}

type eventTry struct {
	id uuid.UUID
}

func (n eventTry) event() {}

func (n eventTry) String() string {
	return "Try"
}

type eventDeployCompleted struct {
	id uuid.UUID
}

func (n eventDeployCompleted) event() {}

func (n eventDeployCompleted) String() string {
	return "DeployCompleted"
}

type eventStop struct{}

func (n eventStop) event() {}

func (n eventStop) String() string {
	return "Stop"
}

type eventHealthy struct {
	containerId string
}

func (n eventHealthy) event() {}

func (n eventHealthy) String() string {
	return "Healthy"
}

type eventUnhealthy struct {
	containerId string
}

func (n eventUnhealthy) event() {}

func (n eventUnhealthy) String() string {
	return "Unhealthy"
}

type Snapshot interface {
	fmt.Stringer
	apply(instance *Instance, e event) Snapshot
}

type Init struct {
}

func (x *Init) String() string {
	return "Init"
}

type Stopped struct {
}

func (x *Stopped) String() string {
	return "Stopped"
}

type Wait struct {
	Container *docker.Container
}

func (x *Wait) String() string {
	return "Wait"
}

type TryAgain struct {
	id   uuid.UUID
	Spec *spec.Spec
}

func (x *TryAgain) String() string {
	return "TryAgain"
}

type Stable struct {
	Container *docker.Container
}

func (x *Stable) String() string {
	return "Stable"
}

type WaitNext struct {
	Current *docker.Container
	Next    *docker.Container
}

func (x *WaitNext) String() string {
	return "WaitNext"
}

type TryAgainNext struct {
	Current *docker.Container
	id      uuid.UUID
	Spec    *spec.Spec
}

func (x *TryAgainNext) String() string {
	return "TryAgainNext"
}

type BothStarted struct {
	Prev *docker.Container
	Next *docker.Container
	id   uuid.UUID
}

func (x *BothStarted) String() string {
	return "BothStarted"
}

func (x *Instance) scheduleTry() uuid.UUID {
	tryID := uuid.NewV4()
	go func() {
		x.group.Add(1)
		defer x.group.Done()

		select {
		case <-time.After(5 * time.Second):
		case <-x.done:
			return
		}

		select {
		case x.events <- eventTry{id: tryID}:
		case <-x.done:
		}
	}()
	return tryID
}

func (x *Instance) scheduleDeployCompleted(duration time.Duration) uuid.UUID {
	tryID := uuid.NewV4()
	go func() {
		x.group.Add(1)
		defer x.group.Done()

		select {
		case <-time.After(duration):
		case <-x.done:
			return
		}

		select {
		case x.events <- eventDeployCompleted{id: tryID}:
		case <-x.done:
		}
	}()
	return tryID
}

func (x *Instance) startHealthchecks(container *docker.Container) {
	x.group.Add(1)
	defer x.group.Done()
	res := make(chan event, 1)
	go func() {
		var e event
		if container.WaitHealthchecks() {
			e = eventHealthy{containerId: container.Id}
		} else {
			e = eventUnhealthy{containerId: container.Id}
		}
		res <- e
	}()

	select {
	case e := <-res:
		x.events <- e
	case <-x.done:
	}
}

func (x *Instance) startOrTryAgain(spec *spec.Spec) Snapshot {
	container, err := x.system.Docker.Start(x.logger, x.Name, spec)
	if err != nil {
		x.logger.WithError(err).Warn("Can't start container, will try again later")
		uuid := x.scheduleTry()
		return &TryAgain{id: uuid, Spec: spec}
	}
	go x.startHealthchecks(container)
	return &Wait{Container: container}
}

func (x *Instance) startOrTryAgainNext(current *docker.Container, spec *spec.Spec) Snapshot {
	container, err := x.system.Docker.Start(x.logger, x.Name, spec)
	if err != nil {
		x.logger.WithError(err).Warn("Can't start container, will try again later")
		uuid := x.scheduleTry()
		return &TryAgainNext{Current: current, id: uuid, Spec: spec}
	}
	go x.startHealthchecks(container)
	return &WaitNext{Current: current, Next: container}
}

func (s *Init) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		return instance.startOrTryAgain(e.spec)
	case eventStop:
		return &Stopped{}
	}
}

func (s *Wait) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		s.Container.Stop()
		return instance.startOrTryAgain(e.spec)
	case eventHealthy:
		if e.containerId == s.Container.Id {
			return &Stable{Container: s.Container}
		}
		return s
	case eventUnhealthy:
		if e.containerId == s.Container.Id {
			instance.logger.Warn("Deployed container is in unhealthy state")
			return s
		}
		return s
	case eventStop:
		s.Container.Stop()
		return &Stopped{}
	}
}

func (s *TryAgain) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		return instance.startOrTryAgain(e.spec)
	case eventTry:
		if e.id == s.id {
			return instance.startOrTryAgain(s.Spec)
		}
		return s
	case eventStop:
		return &Stopped{}
	}
}

func (s *Stable) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		if s.Container.Spec.IsBefore() {
			s.Container.Stop()
			return instance.startOrTryAgain(e.spec)
		}
		return instance.startOrTryAgainNext(s.Container, e.spec)
	case eventStop:
		s.Container.Stop()
		return &Stopped{}
	}
}

func (s *WaitNext) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		if e.spec.IsBefore() {
			s.Current.Stop()
			s.Next.Stop()
			return instance.startOrTryAgain(e.spec)
		}
		s.Next.Stop()

		return instance.startOrTryAgainNext(s.Current, e.spec)
	case eventHealthy:
		if e.containerId == s.Next.Id {
			instance.scheduleDeployCompleted(time.Duration(s.Current.Spec.AfterTimeout()) * time.Second)
			return &BothStarted{Prev: s.Current, Next: s.Next}
		}
		return s
	case eventUnhealthy:
		if e.containerId == s.Next.Id {
			instance.logger.Warn("Next container is unhealthy, will stop it and try to start later again")
			s.Next.Stop()
			uuid := instance.scheduleTry()
			return &TryAgainNext{Current: s.Current, id: uuid, Spec: s.Next.Spec}
		}
		return s
	case eventStop:
		s.Current.Stop()
		s.Next.Stop()
		return &Stopped{}
	}
}

func (s *TryAgainNext) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		return instance.startOrTryAgainNext(s.Current, e.spec)
	case eventTry:
		if e.id == s.id {
			return instance.startOrTryAgainNext(s.Current, s.Spec)
		}
		return s
	case eventStop:
		s.Current.Stop()
		return &Stopped{}
	}
}

func (s *BothStarted) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		s.Prev.Stop()
		return instance.startOrTryAgainNext(s.Next, e.spec)
	case eventDeployCompleted:
		s.Prev.Stop()
		return &Stable{Container: s.Next}
	case eventStop:
		s.Prev.Stop()
		s.Next.Stop()
		return &Stopped{}
	}
}

func (s *Stopped) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	}
}
