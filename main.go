package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"syscall"

	"io/ioutil"

	log "github.com/Sirupsen/logrus"
	dockerTypes "github.com/docker/docker/api/types"
	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"

	"path/filepath"

	"github.com/jawher/mow.cli"
)

type dockerAuths []docker.Auth

var dockerAuthRexexp = regexp.MustCompile(`^(.+):(.+):(.+)$`)

func (x *dockerAuths) Set(v string) error {
	parsed := dockerAuthRexexp.FindStringSubmatch(v)
	if parsed == nil {
		return errors.New("auth pair should have format of host:login:password")
	}
	*x = append(*x, docker.Auth{
		Registry: parsed[1],
		Config: &dockerTypes.AuthConfig{
			Username: parsed[2],
			Password: parsed[3],
		}})
	return nil
}

func (x *dockerAuths) String() string {
	return fmt.Sprintf("%v", *x)
}

func (x *dockerAuths) Clear() {
	*x = nil
}

func main() {
	app := cli.App("condo", "Reliable and simple idempotent supervisor for Docker containers")
	app.Version("version", humanVersion)

	auths := dockerAuths{}
	app.VarOpt("docker-auth", &auths, "Docker registry host:login:password")

	app.Spec = "[--docker-auth]..."

	app.Command("execute", "Start docker container from provided EDN spec", func(cmd *cli.Cmd) {
		specPath := cmd.StringArg("PATH", "", "")
		cmd.Action = func() {
			content, err := ioutil.ReadFile(*specPath)
			if err != nil {
				log.WithField("path", specPath).WithError(err).Fatal("Can't read")
			}
			s, err := spec.Parse(content)
			if err != nil {
				log.WithField("path", specPath).WithError(err).Fatal("Can't parse")
			}
			docker := docker.New(auths)
			name := filepath.Base(*specPath)
			docker.Start(log.NewEntry(log.StandardLogger()), name[0:len(name)-len(filepath.Ext(name))], s)
		}
	})

	app.Command("start", "Start condo daemon with specs provider", func(cmd *cli.Cmd) {
		directory := cmd.StringOpt("directory", "", "Path to directory with condo's specs")
		cmd.Spec = "--directory"
		cmd.Action = func() {
			sigs := make(chan os.Signal, 1)
			signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
			stat, err := os.Stat(*directory)
			if err != nil {
				log.WithField("path", directory).WithError(err).Fatal("Can't read a directory")
			}
			if !stat.IsDir() {
				log.WithField("path", directory).Fatal("Isn't a directory")
			}
			docker := docker.New(auths)
			specs := system.NewDirectorySpecs(*directory)
			system := system.New(docker, specs)

			sup := supervisor.New(system)
			sup.Start()

			<-sigs
			sup.Stop()

		}
	})

	app.Run(os.Args)
}
