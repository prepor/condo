package system

import (
	"path/filepath"
	"time"

	"io/ioutil"

	"bytes"

	"github.com/Sirupsen/logrus"
	log "github.com/Sirupsen/logrus"
	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/util"
)

type Specer interface {
	WatchSpecs(done <-chan struct{}) <-chan WatchEvent
	ReceiveSpecs(name string, done <-chan struct{}) <-chan *spec.Spec
}

type System struct {
	Docker *docker.Docker
	Specs  Specer
}

func New(docker *docker.Docker, specs Specer) *System {
	return &System{
		Docker: docker,
		Specs:  specs,
	}
}

type directorySpecs struct {
	path   string
	logger *logrus.Entry
}

func NewDirectorySpecs(path string) Specer {
	return &directorySpecs{
		path:   path,
		logger: log.WithField("directory", path),
	}
}

func (x *directorySpecs) readDirTick() (res []string, err error) {
	files, err := ioutil.ReadDir(x.path)
	if err != nil {
		return
	}
	for _, v := range files {
		if filepath.Ext(v.Name()) == ".edn" && v.Name() != "self.edn" {
			res = append(res, v.Name()[0:len(v.Name())-4])
		}
	}
	return
}

type WatchEvent interface {
	SpecName() string
}

type NewSpec struct {
	name string
}

func (x NewSpec) SpecName() string {
	return x.name
}

type RemovedSpec struct {
	name string
}

func (x RemovedSpec) SpecName() string {
	return x.name
}

func (x *directorySpecs) WatchSpecs(done <-chan struct{}) <-chan WatchEvent {
	output := make(chan WatchEvent, 5)
	var names, prevNames []string
	var err error
	go func() {
		for {
			names, err = x.readDirTick()
			if err != nil {
				x.logger.WithError(err).Warn("Can't read specs dir")
			} else {
				new, removed := util.DiffStrings(prevNames, names)
				for _, n := range new {
					select {
					case <-done:
						close(output)
						return
					case output <- NewSpec{name: n}:
					}
				}

				for _, n := range removed {
					select {
					case <-done:
						close(output)
						return
					case output <- RemovedSpec{name: n}:
					}
				}
			}

			select {
			case <-done:
				close(output)
				return
			case <-time.After(time.Second):
			}
			prevNames = names
		}
	}()
	return output
}

func (x *directorySpecs) readTick(logger *logrus.Entry, path string, prevContent []byte) ([]byte, *spec.Spec) {
	content, err := ioutil.ReadFile(path)
	if err != nil {
		logger.WithError(err).Warn("Can't read spec file")
		return prevContent, nil
	}
	if bytes.Equal(content, prevContent) {
		return prevContent, nil
	}
	spec, err := spec.Parse(content)
	if err != nil {
		logger.WithError(err).Warn("Can't parse spec file")
		return prevContent, nil
	}
	return content, spec
}

func (x *directorySpecs) ReceiveSpecs(name string, done <-chan struct{}) <-chan *spec.Spec {
	logger := x.logger.WithField("specName", name)
	output := make(chan *spec.Spec, 5)
	var (
		path        string
		prevContent []byte
		parsed      *spec.Spec
	)
	go func() {
		for {
			path = filepath.Join(x.path, name) + ".edn"
			prevContent, parsed = x.readTick(logger, path, prevContent)
			if parsed != nil {
				select {
				case <-done:
					close(output)
					return
				case output <- parsed:
				}
			} else {
				select {
				case <-done:
					close(output)
					return
				case <-time.After(2 * time.Second):
				}
			}
		}
	}()
	return output
}
