package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"math/rand"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Docker struct {
	Endpoint   string
	HTTPClient *http.Client
	Host       string
}

type Container struct {
	Id           string
	Spec         *Spec
	PortsMapping map[uint]uint
	StopWaiting  chan bool
}

const (
	defaultCaFile   = "ca.pem"
	defaultKeyFile  = "key.pem"
	defaultCertFile = "cert.pem"
)

func newHttpsClient(dockerCertPath string) *http.Client {
	certFile := filepath.Join(dockerCertPath, defaultCertFile)
	keyFile := filepath.Join(dockerCertPath, defaultKeyFile)
	caFile := filepath.Join(dockerCertPath, defaultCaFile)
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatal(err)
	}
	// Load CA cert
	caCert, err := ioutil.ReadFile(caFile)
	if err != nil {
		log.Fatal(err)
	}
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(caCert)
	// Setup HTTPS client
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
	}
	tlsConfig.BuildNameToCertificate()
	transport := &http.Transport{TLSClientConfig: tlsConfig}
	return &http.Client{Transport: transport}
}

func NewDocker(dockerEndpoint string, dockerCertPath string) *Docker {
	if !(strings.HasPrefix(dockerEndpoint, "http://") ||
		strings.HasPrefix(dockerEndpoint, "https://")) {
		dockerEndpoint = "http://" + dockerEndpoint
	}
	url, err := url.Parse(dockerEndpoint)
	if err != nil {
		log.Fatal(err)
	}
	parts := strings.Split(url.Host, ":")
	var client *http.Client
	if dockerCertPath != "" {
		client = newHttpsClient(dockerCertPath)
	} else {
		client = http.DefaultClient
	}
	return &Docker{
		Endpoint:   dockerEndpoint,
		HTTPClient: client,
		Host:       parts[0],
	}

}

func (docker *Docker) waitForContainer(container *Container) {
	containerStopped := make(chan bool)
	// start goroutine with wait request
	go func(out chan bool) {
		url := docker.Endpoint + fmt.Sprintf("/containers/%s/wait", container.Id)
		fmt.Printf("Will wait for container %s: %s\n", container.Id, url)
		req, err := http.NewRequest("POST", url, nil)
		if err != nil {
			fmt.Println("Error while trying to wait for container:", err)
			return
		}
		res, code, err := dockerRequest(docker, req)
		// any response from here means container has been stopped
		fmt.Printf("Container %s stopped with code %d, res: %s, error: %v\n", container.Id, code, res, err)
		close(out)
	}(containerStopped)
	select {
	case <-container.StopWaiting:
		// XXX: If we've got this message, the target container is
		// about to stop, so we do not need to do anything about
		// goroutine above, it will just finishes.
		fmt.Printf("No longer waiting for container %s\n", container.Id)
		return
	case <-containerStopped:
		fmt.Printf("Unexpected stop of container %s! Bailing out...\n", container.Id)
		os.Exit(1)
	}
}

func (docker *Docker) StopContainer(container *Container) error {
	fmt.Printf("Stop waiting for container %s...\n", container.Id)
	close(container.StopWaiting)
	url := docker.Endpoint + fmt.Sprintf("/containers/%s/stop?t=%d", container.Id, container.Spec.KillTimeout)
	fmt.Printf("Stop docker container %s: %s\n", container.Id, url)
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

	fmt.Printf("Docker container %s stopped\n", container.Id)

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
	fmt.Printf("Docker image %s:%s pull: %s\n", imageSpec.Name, imageSpec.Tag, url)
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
	fmt.Printf("Docker image %s:%s pulled\n", imageSpec.Name, imageSpec.Tag)

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

type logConfig struct {
	Type   string
	Config map[string]string
}

type hostConfig struct {
	Binds        []string
	PortBindings map[string][]dockerPort
	Privileged   bool
	NetworkMode  string
	LogConfig    logConfig
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
	fmt.Printf("Docker container %s delete: %s\n", container.Id, url)
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
	fmt.Printf("Docker container %s deleted\n", container.Id)

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
	fmt.Printf("Docker container %s set ports mapping: %s\n", container.Id, url)
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
		fmt.Println("Can't unmarhsal %s -- %s", res, err)
		return err
	}

	for _, s := range container.Spec.Services {
		var protocol string
		if s.Udp {
			protocol = "udp"
		} else {
			protocol = "tcp"
		}
		if container.Spec.NetworkMode == "host" {
			container.PortsMapping[s.Port] = s.Port
		} else {
			p, err := strconv.ParseUint(resp.NetworkSettings.Ports[fmt.Sprintf("%d/%s", s.Port, protocol)][0].HostPort, 10, 0)
			if err != nil {
				return err
			}
			container.PortsMapping[s.Port] = uint(p)
		}
	}
	return nil
}

var letters = []rune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

func randSeq(n int) string {
	b := make([]rune, n)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func (docker *Docker) renameExistsContainer(name string) {
	n := fmt.Sprintf("%s_%s", name, randSeq(10))
	url := docker.Endpoint + fmt.Sprintf("/containers/%s/rename?name=%s", name, n)
	fmt.Printf("Docker container %s rename to %s: %s\n", name, n, url)
	req, err := http.NewRequest("POST", url, nil)
	if err != nil {
		return
	}
	dockerRequest(docker, req)
}

func (docker *Docker) CreateContainer(spec *Spec) (*Container, error) {
	url := docker.Endpoint + "/containers/create"
	if spec.Name != "" {
		docker.renameExistsContainer(spec.Name)
		url = fmt.Sprintf("%s?name=%s", url, spec.Name)
	}
	fmt.Printf("Docker create container from %s: %s\n", spec.Image.Id, url)
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

	logs := logConfig{}
	if spec.Logs != nil {
		logs.Type = spec.Logs.Type
		logs.Config = spec.Logs.Config
	} else {
		logs.Type = "syslog"
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
			NetworkMode:  spec.NetworkMode,
			LogConfig:    logs,
		},
	}
	body, err := json.Marshal(cmd)
	if err != nil {
		return nil, err
	}
	fmt.Printf("Docker create container from cmd: %s\n", string(body))
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	res, code, err := dockerRequest(docker, req)
	if err != nil {
		return nil, err
	} else if code != 201 {
		return nil, errors.New(fmt.Sprintf("Container create: bad http-status %s; %s %+v", code, res, spec))
	}
	resp := &createContainerResp{}
	json.Unmarshal(res, resp)
	if len(resp.Warnings) > 0 {
		fmt.Println("Create container: warnings:", resp.Warnings)
	}
	container := &Container{Id: resp.Id, Spec: spec, PortsMapping: make(map[uint]uint)}
	fmt.Printf("Docker container %s created\n", container.Id)

	url = docker.Endpoint + fmt.Sprintf("/containers/%s/start", container.Id)
	fmt.Printf("Docker container %s start: %s\n", container.Id, url)

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
		return nil, errors.New(fmt.Sprintf("Container start: bad http-status %s; %s %+v", code, res, spec))
	}

	err = docker.setPortsMapping(container)
	if err != nil {
		return nil, err
	}
	container.StopWaiting = make(chan bool)
	go docker.waitForContainer(container)
	fmt.Printf("Docker container %s creeated and started!\n", container.Id)
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
