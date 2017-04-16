package instance

import (
	"context"
	"time"

	"github.com/Sirupsen/logrus"
	"github.com/prepor/condo/docker"
)

type Container struct {
	*docker.Container
	instance *Instance
	done     chan struct{}
}

func containerInit(instance *Instance, container *docker.Container) *Container {
	c := &Container{
		Container: container,
		instance:  instance,
		done:      make(chan struct{}),
	}
	c.instance.group.Add(1)
	go c.waitHealthchecks()
	if container.Spec.WatchImage {
		c.instance.group.Add(1)
		go c.watchImage()

	}
	return c
}

func (x *Container) Stop() {
	close(x.done)
	x.Container.Stop()
}

// WaitHealthchecks checks status of the running container.
// In case of any fail it continues to wait for success result but at most timeout
func (x *Container) waitHealthchecks() {
	defer x.instance.group.Done()

Loop:
	for {
		select {
		case <-x.done:
			break Loop
		case <-time.After(2 * time.Second):
			res, err := x.instance.system.Docker.ContainerInspect(context.Background(), x.Id)
			if err != nil {
				x.instance.logger.WithError(err).Warn("Error while container inspecting")
				continue Loop
			}
			state := res.State
			var healthStatus string
			if state.Health != nil {
				healthStatus = state.Health.Status
			}

			x.instance.logger.WithFields(logrus.Fields{
				"health-status": healthStatus,
				"status":        state.Status,
			}).Debug("Healthcheck tick")
			if healthStatus == "healthy" || (healthStatus == "" && state.Running == true) {
				t := time.Now()
				x.StableAt = &t
				x.instance.events <- eventHealthy{x.Id}
				return
			}

		}

	}
}

func (x *Container) watchImage() {
	defer x.instance.group.Done()

Loop:
	for {
		select {
		case <-x.done:
			break Loop
		case <-time.After(5 * time.Second):
			if err := x.instance.system.Docker.ImagePull2(x.Spec.Image()); err != nil {
				x.instance.logger.WithError(err).Warn("Error while image pulling")
				continue Loop
			}

			res, _, err := x.instance.system.Docker.ImageInspectWithRaw(context.Background(), x.Spec.Image())
			if err != nil {
				x.instance.logger.WithError(err).Warn("Error while container inspecting")
				continue Loop
			}

			if res.ID != x.Image {
				x.instance.logger.
					WithField("was", x.Image).
					WithField("now", res.ID).
					Info("New image version available")
				x.instance.events <- eventNewSpec{x.Spec}
				return
			}
		}

	}
}
