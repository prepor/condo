package proxy

import (
	"fmt"
	"io"
	"net"
	"sync"

	"github.com/Sirupsen/logrus"
	"github.com/docker/docker/api/types/network"
	"github.com/prepor/condo/docker"
)

type frontends struct {
	*sync.Mutex
	dict map[string]*InstanceProxy
}

type Proxy struct {
	frontends *frontends
}

type InstanceProxy struct {
	*sync.RWMutex
	backend  string
	listener net.Listener
	logger   *logrus.Entry
	proxy    *Proxy
	done     chan struct{}
	listen   string
}

type subscriptionKeyType string

var subscriptionKey = subscriptionKeyType("proxy")

func New() *Proxy {
	return &Proxy{
		frontends: &frontends{
			Mutex: &sync.Mutex{},
			dict:  make(map[string]*InstanceProxy),
		},
	}
}

func (x *Proxy) NewInstanceProxy(logger *logrus.Entry, container *docker.Container) (*InstanceProxy, error) {
	x.frontends.Lock()
	defer x.frontends.Unlock()

	listen := container.Spec.Proxy.Listen
	instance := &InstanceProxy{
		RWMutex: &sync.RWMutex{},
		logger:  logger,
		proxy:   x,
		listen:  listen,
	}

	instance.startListener(listen)

	if err := instance.setBackend(container); err != nil {
		return nil, err
	}

	return instance, nil
}

func (x *InstanceProxy) SetBackend(container *docker.Container) error {
	if container.Spec.Proxy.Listen != x.listen {
		x.proxy.frontends.Lock()
		defer x.proxy.frontends.Unlock()
		x.stop()
		if err := x.startListener(container.Spec.Proxy.Listen); err != nil {
			return err
		}
	}
	return x.setBackend(container)
}

func (x *InstanceProxy) startListener(listen string) error {
	if _, ok := x.proxy.frontends.dict[listen]; ok {
		return fmt.Errorf("%s address is already used for proxing", listen)
	}

	x.logger.WithField("listen", listen).Info("Start proxy")

	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}

	x.listen = listen
	x.listener = ln
	x.done = make(chan struct{})

	go func() {
		for {
			cn, err := ln.Accept()
			if err != nil {
				select {
				case <-x.done:
					return
				default:
				}
				x.logger.WithError(err).Warn("Failed to accept connection in proxy")
				continue
			}
			go x.handleConnection(cn)
		}
	}()
	return nil
}

func (x *InstanceProxy) setBackend(container *docker.Container) error {
	var endpoint *network.EndpointSettings
	destNetwork := container.Spec.Proxy.DestinationNetwork
	if destNetwork != "" {
		endpoint = container.Network.Networks[destNetwork]
		if endpoint == nil {
			return fmt.Errorf("There is no %s network for %s container, can't proxy", destNetwork, container.Id)
		}
	} else {

		if len(container.Network.Networks) == 0 {
			// is this possible? not sure
			return fmt.Errorf("Container %s doesn't connect to any network, can't proxy to it", container.Id)
		}
		for _, v := range container.Network.Networks {
			endpoint = v
			break
		}
	}
	port := container.Spec.Proxy.DestinationPort
	if port == 0 {
		return fmt.Errorf("destination-port should be set to proxy")
	}

	x.Lock()
	x.backend = fmt.Sprintf("%s:%d", endpoint.IPAddress, port)
	x.Unlock()
	return nil
}

func (x *InstanceProxy) Stop() {
	x.proxy.frontends.Lock()
	defer x.proxy.frontends.Unlock()
	x.stop()
}

func (x *InstanceProxy) stop() {
	close(x.done)
	x.listener.Close()
	delete(x.proxy.frontends.dict, x.listen)
}

func (x *InstanceProxy) handleConnection(cn net.Conn) {
	x.RLock()
	defer x.RUnlock()
	defer cn.Close()

	dest, err := net.Dial("tcp", x.backend)
	if err != nil {
		x.logger.WithError(err).Errorf("Failed to dial proxy address %s", x.backend)
		return
	}
	defer dest.Close()

	x.logger.Debugf("Accepted %s to forward to %s", cn.RemoteAddr(), x.backend)

	notify := make(chan error, 2)

	go (func() {
		_, err := io.Copy(dest, cn)
		notify <- err
	})()
	go (func() {
		_, err := io.Copy(cn, dest)
		notify <- err
	})()

	err = <-notify
	if err != nil {
		x.logger.WithError(err).Debugf("Failed to proxy")
	}

	cn.Close()
	dest.Close()
	<-notify
}
