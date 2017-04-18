package instance

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/prepor/condo/spec"
	uuid "github.com/satori/go.uuid"
)

type Snapshot interface {
	fmt.Stringer
	json.Marshaler
	apply(instance *Instance, e event) Snapshot
}

type Init struct {
}

type Stopped struct {
}

func (x *Instance) transitStopped() *Stopped {
	x.ensureStoppedProxy()
	return &Stopped{}
}

type Wait struct {
	Container *Container
}

func (x *Instance) transitWait(container *Container) *Wait {
	x.ensureStoppedProxy()
	return &Wait{Container: container}
}

type TryAgain struct {
	id   uuid.UUID
	Spec *spec.Spec
}

func (x *Instance) transitTryAgain(id uuid.UUID, spec *spec.Spec) *TryAgain {
	x.ensureStoppedProxy()
	return &TryAgain{id: id, Spec: spec}
}

type Stable struct {
	Container *Container
}

func (x *Instance) transitStable(container *Container) *Stable {
	return &Stable{Container: container}
}

type WaitNext struct {
	Current *Container
	Next    *Container
}

func (x *Instance) transitWaitNext(current, next *Container) *WaitNext {
	return &WaitNext{Current: current, Next: next}
}

type TryAgainNext struct {
	Current *Container
	id      uuid.UUID
	Spec    *spec.Spec
}

func (x *Instance) transitTryAgainNext(current *Container, id uuid.UUID, spec *spec.Spec) *TryAgainNext {
	return &TryAgainNext{Current: current, id: id, Spec: spec}
}

type BothStarted struct {
	Prev *Container
	Next *Container
	id   uuid.UUID
}

func (x *Instance) transitBothStarted(prev, next *Container) *BothStarted {
	id := x.scheduleDeployCompleted(time.Duration(prev.Spec.AfterTimeout()) * time.Second)
	return &BothStarted{Prev: prev, Next: next, id: id}
}

func (x *Instance) scheduleTry() uuid.UUID {
	tryID := uuid.NewV4()
	x.group.Add(1)
	go func() {
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
	x.group.Add(1)
	go func() {
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

func (x *Instance) startOrTryAgain(spec *spec.Spec) Snapshot {
	dockerContainer, err := x.system.Docker.Start(x.logger, x.Name, spec)
	if err != nil {
		x.logger.WithError(err).Warn("Can't start container, will try again later")
		uuid := x.scheduleTry()
		return x.transitTryAgain(uuid, spec)
	}
	container := containerInit(x, dockerContainer)
	return x.transitWait(container)
}

func (x *Instance) startOrTryAgainNext(current *Container, spec *spec.Spec) Snapshot {
	dockerContainer, err := x.system.Docker.Start(x.logger, x.Name, spec)
	if err != nil {
		x.logger.WithError(err).Warn("Can't start container, will try again later")
		uuid := x.scheduleTry()
		return x.transitTryAgainNext(current, uuid, spec)
	}

	container := containerInit(x, dockerContainer)
	return x.transitWaitNext(current, container)
}

func (s *Init) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	case eventNewSpec:
		return instance.startOrTryAgain(e.spec)
	case eventStop:
		return instance.transitStopped()
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
			err := instance.ensureProxy(s.Container)
			if err != nil {
				instance.logger.WithError(err).Error("Can't transit to stable")
				s.Container.Stop()
				uuid := instance.scheduleTry()
				return instance.transitTryAgain(uuid, s.Container.Spec)
			}
			return instance.transitStable(s.Container)
		}
		return s
	case eventStop:
		s.Container.Stop()
		return instance.transitStopped()
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
		return instance.transitStopped()
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
		return instance.transitStopped()
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
			err := instance.ensureProxy(s.Next)
			if err != nil {
				instance.logger.WithError(err).Error("Can't transit to both started")
				s.Next.Stop()
				uuid := instance.scheduleTry()
				return instance.transitTryAgainNext(s.Current, uuid, s.Next.Spec)
			}

			return instance.transitBothStarted(s.Current, s.Next)
		}
		return s
	case eventStop:
		s.Current.Stop()
		s.Next.Stop()
		return instance.transitStopped()
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
		return instance.transitStopped()
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
		if e.id == s.id {
			s.Prev.Stop()
			return instance.transitStable(s.Next)
		}
		return s
	case eventStop:
		s.Prev.Stop()
		s.Next.Stop()
		return instance.transitStopped()
	}
}

func (s *Stopped) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	}
}
