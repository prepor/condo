package instance

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/prepor/condo/docker"
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

func (x *Init) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Init
	}{"Init", *x})
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

func (x *Wait) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Wait
	}{"Wait", *x})
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

func (x *TryAgain) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		TryAgain
	}{"TryAgain", *x})
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

func (x *Stable) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Stable
	}{"Stable", *x})
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

func (x *WaitNext) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		WaitNext
	}{"WaitNext", *x})
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

func (x *TryAgainNext) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		TryAgainNext
	}{"TryAgainNext", *x})
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

func (x *BothStarted) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		BothStarted
	}{"BothStarted", *x})
}

func (s *Stopped) apply(instance *Instance, e event) Snapshot {
	switch e := e.(type) {
	default:
		instance.logger.WithField("event", e).Warn("Unexpected event")
		return s
	}
}

func (x *Stopped) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Stopped
	}{"Stopped", *x})
}
