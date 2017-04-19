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
	Image     string
	Network   *dockerTypes.NetworkSettings
	logger    *logrus.Entry
	docker    *Docker
}

type Docker struct {
	*client.Client
	auths []Auth
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
		Client: cli,
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

func (d *Docker) ImagePull2(image string) error {
	credentials := d.getCredentials(image)

	r, err := d.ImagePull(context.Background(), image,
		dockerTypes.ImagePullOptions{
			RegistryAuth: credentials,
		})
	if err != nil {
		return err
	}

	if _, err = io.Copy(ioutil.Discard, r); err != nil {
		return err
	}
	return nil
}

func (d *Docker) Start(l *logrus.Entry, name string, spec *spec.Spec) (container *Container, err error) {
	l.Info("Start container")
	config, hostConfig, networkingConfig, err := spec.ContainerConfigs()
	l.Debug("Container config:", spew.Sdump(config, hostConfig, networkingConfig))
	if err != nil {
		return
	}

	ctx := context.Background()
	l.WithField("image", config.Image).
		WithField("credentials", d.getCredentials(config.Image)).
		Info("Image pull")

	l.WithField("image", config.Image).Info("Image pulled")
	d.ImagePull2(config.Image)

	var containerName string

	if spec.Name != "" {
		containerName = spec.Name
	} else {
		containerName = fmt.Sprintf("%s_%s", name, util.RandStringBytes(10))
	}

	d.ContainerRemove(ctx, containerName, dockerTypes.ContainerRemoveOptions{Force: true})

	createdRes, err := d.ContainerCreate(ctx, config, hostConfig, networkingConfig, containerName)
	if err != nil {
		return
	}

	l = l.WithField("id", createdRes.ID)

	l.Info("Container created")

	err = d.ContainerStart(ctx, createdRes.ID, dockerTypes.ContainerStartOptions{})

	if err != nil {
		return
	}

	l.Info("Container started")

	info, err := d.ContainerInspect(context.Background(), createdRes.ID)
	if err != nil {
		l.WithError(err).Warn("Error while container inspecting")
		timeout := time.Duration(spec.StopTimeout) * time.Second
		d.ContainerStop(context.Background(), createdRes.ID, &timeout)
		return
	}

	started := time.Now()
	container = &Container{
		Id:        createdRes.ID,
		Spec:      spec,
		StartedAt: &started,
		Image:     info.Image,
		Network:   info.NetworkSettings,
		logger:    l,
		docker:    d,
	}

	return
}

// Stop container. In case of fail it logs Warning
func (c Container) Stop() {
	c.logger.Info("Stop container")
	timeout := time.Duration(c.Spec.StopTimeout) * time.Second
	err := c.docker.ContainerStop(context.Background(), c.Id, &timeout)
	if err != nil {
		c.logger.WithError(err).Warn("Error while container stop")
	}
}
