package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"net"
	"net/http"
	"net/http/httputil"
	"strconv"
)

type Docker struct {
	Endpoint   string
	HTTPClient *http.Client
}

type Container struct {
	Id           string
	Spec         *Spec
	PortsMapping map[uint]uint
}

func NewDocker(docker_endpoint string) *Docker {
	return &Docker{
		Endpoint:   docker_endpoint,
		HTTPClient: http.DefaultClient,
	}
}

func detectContainer(docker *Docker, endpoint string) *Container {
	return nil
}

func (docker *Docker) StopContainer(container *Container) error {
	url := docker.Endpoint + fmt.Sprintf("/containers/%s/stop?t=%d", container.Id, container.Spec.KillTimeout)
	fmt.Println("Stop docker container", url)
	req, err := http.NewRequest("POST", url, nil)
	if err != nil {
		return err
	}
	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return err
	}

	if code == 500 {
		return errors.New(fmt.Sprintf("Container stopping: bad http-status %d; %s %+v", code, res, container))
	}

	err = docker.deleteContainer(container)
	if err != nil {
		return err
	}

	fmt.Println("Docker container stopped", url)

	return nil
}

type jsonMessage struct {
	Status   string `json:"status,omitempty"`
	Progress string `json:"progress,omitempty"`
	Error    string `json:"error,omitempty"`
	Stream   string `json:"stream,omitempty"`
}

func checkStream(stream io.Reader) error {
	dec := json.NewDecoder(stream)
	for {
		var m jsonMessage
		if err := dec.Decode(&m); err == io.EOF {
			break
		} else if err != nil {
			return err
		}

		if m.Stream != "" {
			fmt.Print(m.Stream)
		} else if m.Progress != "" {
			fmt.Printf("%s %s\r", m.Status, m.Progress)
		} else if m.Error != "" {
			return errors.New(m.Error)
		}
		if m.Status != "" {
			fmt.Println(m.Status)
		}
	}
	return nil
}

func (docker *Docker) pullImage(imageSpec *ImageSpec) error {
	url := docker.Endpoint + "/images/create" + fmt.Sprintf("?fromImage=%s&tag=%s", imageSpec.Name, imageSpec.Tag)
	fmt.Println("Pull docker image", url)
	req, err := http.NewRequest("POST", url, nil)
	if err != nil {
		return err
	}
	res, _, err := dockerRequest(docker, req)
	if err != nil {
		return err
	}
	if err := checkStream(bytes.NewBuffer(res)); err != nil {
		return err
	}
	fmt.Println("Docker image pulled", url)

	return nil
}

type Image struct {
	ID string
}

func (docker *Docker) InspectImage(name string, tag string) (*Image, error) {
	var err error
	fullName := name
	if tag != "" {
		fullName += ":" + tag
	}
	url := docker.Endpoint + fmt.Sprintf("/images/%s/json", fullName)
	fmt.Println("Inspect docker image", url)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return nil, err
	} else if code != 200 {
		return nil, errors.New(fmt.Sprintf("Image inspecting: bad http-status %s; %s", code, res))
	}
	var image Image
	err = json.Unmarshal(res, &image)
	if err != nil {
		return nil, err
	}
	return &image, nil
}

type dockerPort struct {
	HostPort string
}

type hostConfig struct {
	Binds        []string
	PortBindings map[string][]dockerPort
	Privileged   bool
}

type createContainerCmd struct {
	Host       string
	User       string
	Image      string
	Cmd        []string
	Env        []string
	Volumes    map[string]map[string]string
	HostConfig hostConfig
}

type createContainerResp struct {
	Id       string
	Warnings []string
}

func (docker *Docker) deleteContainer(container *Container) error {
	url := docker.Endpoint + fmt.Sprintf("/containers/%s", container.Id)
	fmt.Println("Delete docker container", url)
	req, err := http.NewRequest("DELETE", url, nil)
	if err != nil {
		return err
	}
	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return err
	}

	if code == 500 {
		return errors.New(fmt.Sprintf("Container deleting: bad http-status %d; %s %+v", code, res, container))
	}
	fmt.Println("Docker container deleted", url)

	return nil
}

type dockerInspectRespNetworkSettings struct {
	Ports map[string][]dockerPort
}

type dockerInspectResp struct {
	NetworkSettings dockerInspectRespNetworkSettings
}

func (docker *Docker) setPortsMapping(container *Container) error {
	url := docker.Endpoint + fmt.Sprintf("/containers/%s/json", container.Id)
	fmt.Println("Set container's ports mapping", url)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return err
	} else if code != 200 {
		return errors.New(fmt.Sprint("bad http code", code, res))
	}
	resp := &dockerInspectResp{}
	err = json.Unmarshal(res, resp)
	if err != nil {
		fmt.Printf("Unmarshal error %s\n", res)
		return err
	}

	for _, s := range container.Spec.Services {
		var protocol string
		if s.Udp {
			protocol = "udp"
		} else {
			protocol = "tcp"
		}
		p, err := strconv.ParseUint(resp.NetworkSettings.Ports[fmt.Sprintf("%d/%s", s.Port, protocol)][0].HostPort, 10, 0)
		if err != nil {
			return err
		}
		container.PortsMapping[s.Port] = uint(p)
	}
	return nil
}

func (docker *Docker) CreateContainer(spec *Spec) (*Container, error) {
	url := docker.Endpoint + "/containers/create"
	if spec.Name != "" {
		url = fmt.Sprintf("%s?name=%s", url, spec.Name)
	}
	fmt.Printf("Create docker container (image %s):%s\n", spec.Image.Id, url)
	envs := make([]string, len(spec.Envs))
	for i, e := range spec.Envs {
		envs[i] = fmt.Sprintf("%s=%s", e.Name, e.Value)
	}
	volumes := make(map[string]map[string]string)
	for _, v := range spec.Volumes {
		volumes[v.To] = make(map[string]string)
	}

	binds := make([]string, len(spec.Volumes))
	for i, v := range spec.Volumes {
		binds[i] = fmt.Sprintf("%s:%s", v.From, v.To)
	}

	portBindings := make(map[string][]dockerPort, len(spec.Services))
	for _, s := range spec.Services {
		var hostPort string
		if s.HostPort != 0 {
			hostPort = strconv.Itoa(int(s.HostPort))
		}
		var protocol string
		if s.Udp {
			protocol = "udp"
		} else {
			protocol = "tcp"
		}
		portBindings[fmt.Sprintf("%d/%s", s.Port, protocol)] = []dockerPort{dockerPort{HostPort: hostPort}}
	}
	cmd := &createContainerCmd{
		Host:    spec.Host,
		User:    spec.User,
		Image:   spec.Image.Id,
		Cmd:     spec.Cmd,
		Env:     envs,
		Volumes: volumes,
		HostConfig: hostConfig{
			Binds:        binds,
			PortBindings: portBindings,
			Privileged:   spec.Privileged,
		},
	}
	fmt.Printf("Container spec: %+v", cmd)
	body, err := json.Marshal(cmd)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return nil, err
	} else if code != 201 {
		return nil, errors.New(fmt.Sprintf("container creating: bad http-status %s; %s %+v", code, res, spec))
	}
	resp := &createContainerResp{}
	json.Unmarshal(res, resp)
	if len(resp.Warnings) > 0 {
		fmt.Println("Container creating: warnings: %s", resp.Warnings)
	}
	container := &Container{Id: resp.Id, Spec: spec, PortsMapping: make(map[uint]uint)}

	url = docker.Endpoint + fmt.Sprintf("/containers/%s/start", container.Id)
	fmt.Println("Start docker container", url)

	req, err = http.NewRequest("POST", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	res, code, err = dockerRequest(docker, req)
	if err != nil {
		docker.deleteContainer(container)
		return nil, err
	} else if code == 500 {
		docker.deleteContainer(container)
		return nil, errors.New(fmt.Sprintf("Container starting: bad http-status %s; %s %+v", code, res, spec))
	}

	err = docker.setPortsMapping(container)
	if err != nil {
		return nil, err
	}

	return container, nil
}

func updateSpecId(docker *Docker, imageSpec *ImageSpec) error {
	image, err := docker.InspectImage(imageSpec.Name, imageSpec.Tag)
	if err != nil {
		return err
	}
	imageSpec.Id = image.ID
	return nil
}

func (docker *Docker) DeployContainer(spec *Spec) (*Container, error) {
	var err error
	err = docker.pullImage(&spec.Image)
	if err != nil {
		return nil, err
	}
	err = updateSpecId(docker, &spec.Image)
	if err != nil {
		return nil, err
	}
	container, err := docker.CreateContainer(spec)
	if err != nil {
		return nil, err
	}
	return container, nil
}

func dockerRequest(docker *Docker, request *http.Request) ([]byte, int, error) {
	protocol := request.URL.Scheme
	address := request.URL.Path
	var resp *http.Response
	var err error
	if protocol == "unix" {
		dial, err := net.Dial(protocol, address)
		if err != nil {
			return nil, 0, err
		}
		defer dial.Close()
		clientconn := httputil.NewClientConn(dial, nil)
		resp, err = clientconn.Do(request)
		if err != nil {
			return nil, 0, err
		}
		defer clientconn.Close()
	} else {
		resp, err = docker.HTTPClient.Do(request)
		if err != nil {
			return nil, 0, err
		}
	}

	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, 0, err
	}

	return body, resp.StatusCode, nil
}
