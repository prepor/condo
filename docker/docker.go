package docker

import (
	"context"
	"fmt"
	"io"
	"io/ioutil"

	"time"

	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/Sirupsen/logrus"
	"github.com/davecgh/go-spew/spew"
	dockerTypes "github.com/docker/docker/api/types"
	"github.com/docker/docker/client"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/util"
)

type Container struct {
	Id        string
	Spec      *spec.Spec
	StartedAt *time.Time
	StableAt  *time.Time
	logger    *logrus.Entry
	docker    *Docker
}

type Docker struct {
	client *client.Client
	auths  []Auth
}

type Auth struct {
	Registry string
	Config   *dockerTypes.AuthConfig
}

func New(auths []Auth) *Docker {
	cli, err := client.NewEnvClient()
	if err != nil {
		panic(fmt.Sprintf("Error while docker client initializing: %#v", err))
	}
	return &Docker{
		client: cli,
		auths:  auths,
	}
}

func (d Docker) getCredentials(image string) (res string) {
	s := strings.Split(image, "/")
	if len(s) < 2 {
		return
	}
	for _, v := range d.auths {
		if v.Registry == s[0] {
			resBytes, err := json.Marshal(v.Config)
			if err != nil {
				panic(fmt.Sprintf("Can't marshal auth config: %#v", err))
			}
			res = base64.StdEncoding.EncodeToString(resBytes)
			return
		}
	}
	return
}

func (d *Docker) Start(l *logrus.Entry, name string, spec *spec.Spec) (container *Container, err error) {
	l.Info("Start container")
	config, hostConfig, networkingConfig, err := spec.ContainerConfigs()
	l.Debug("Container config:", spew.Sdump(config, hostConfig, networkingConfig))
	if err != nil {
		return
	}

	ctx := context.Background()

	credentials := d.getCredentials(config.Image)
	l.WithField("image", config.Image).
		WithField("credentials", credentials).
		Info("Image pull")
	r, err := d.client.ImagePull(ctx, config.Image,
		dockerTypes.ImagePullOptions{
			RegistryAuth: credentials,
		})
	if err != nil {
		return
	}
	l.WithField("image", config.Image).Info("Image pulled")

	if _, err = io.Copy(ioutil.Discard, r); err != nil {
		return
	}

	name = fmt.Sprintf("%s_%s", name, util.RandStringBytes(10))

	d.client.ContainerRemove(ctx, name, dockerTypes.ContainerRemoveOptions{Force: true})

	createdRes, err := d.client.ContainerCreate(ctx, config, hostConfig, networkingConfig, name)
	if err != nil {
		return
	}

	l = l.WithField("id", createdRes.ID)

	l.Info("Container created")

	err = d.client.ContainerStart(ctx, createdRes.ID, dockerTypes.ContainerStartOptions{})

	if err != nil {
		return
	}

	l.Info("Container started")

	started := time.Now()
	container = &Container{
		Id:        createdRes.ID,
		Spec:      spec,
		StartedAt: &started,
		logger:    l,
		docker:    d,
	}

	return
}

// Stop container. In case of fail it logs Warning
func (c Container) Stop() {
	c.logger.Info("Stop container")
	timeout := time.Duration(c.Spec.StopTimeout) * time.Second
	err := c.docker.client.ContainerStop(context.Background(), c.Id, &timeout)
	if err != nil {
		c.logger.WithError(err).Warn("Error while container stop")
	}
}

// WaitHealthchecks checks status of the running container.
// In case of any fail it continues to wait for success result but at most timeout
func (c *Container) WaitHealthchecks() bool {
	timeout := time.Duration(c.Spec.StopTimeout) * time.Second
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	checkRes := make(chan bool, 1)
	go func() {
		for {

			time.Sleep(time.Second)
			if ctx.Err() != nil {
				return
			}
			res, err := c.docker.client.ContainerInspect(ctx, c.Id)
			if err != nil {
				c.logger.WithError(err).Warn("Error while container inspecting")
				continue
			}
			state := res.State
			var healthStatus string
			if state.Health != nil {
				healthStatus = state.Health.Status
			}

			c.logger.WithFields(logrus.Fields{
				"health-status": healthStatus,
				"status":        state.Status,
			}).Debug("Healthcheck tick")
			if healthStatus == "healthy" || (healthStatus == "" && state.Running == true) {
				t := time.Now()
				c.StableAt = &t
				checkRes <- true
				return
			}
		}
	}()
	select {
	case <-ctx.Done():
		return false
	case res := <-checkRes:
		return res
	}

}
