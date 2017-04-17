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

type Wait struct {
	Container *Container
}

type TryAgain struct {
	id   uuid.UUID
	Spec *spec.Spec
}

type Stable struct {
	Container *Container
}

type WaitNext struct {
	Current *Container
	Next    *Container
}

type TryAgainNext struct {
	Current *Container
	id      uuid.UUID
	Spec    *spec.Spec
}

type BothStarted struct {
	Prev *Container
	Next *Container
	Id   uuid.UUID `json:"-"`
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
		return &TryAgain{id: uuid, Spec: spec}
	}
	container := containerInit(x, dockerContainer)
	return &Wait{Container: container}
}

func (x *Instance) startOrTryAgainNext(current *Container, spec *spec.Spec) Snapshot {
	dockerContainer, err := x.system.Docker.Start(x.logger, x.Name, spec)
	if err != nil {
		x.logger.WithError(err).Warn("Can't start container, will try again later")
		uuid := x.scheduleTry()
		return &TryAgainNext{Current: current, id: uuid, Spec: spec}
	}

	container := containerInit(x, dockerContainer)

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
		if e.id == s.Id {
			s.Prev.Stop()
			return &Stable{Container: s.Next}
		}
		return s
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
