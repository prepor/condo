package instance

import (
	"fmt"

	"github.com/prepor/condo/spec"
	uuid "github.com/satori/go.uuid"
)

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
