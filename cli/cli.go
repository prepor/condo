package cli

import (
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"syscall"

	log "github.com/Sirupsen/logrus"
	dockerTypes "github.com/docker/docker/api/types"
	cli "github.com/jawher/mow.cli"
	"github.com/prepor/condo/api"
	"github.com/prepor/condo/consul"
	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/expose"
	"github.com/prepor/condo/gossip"
	"github.com/prepor/condo/spec"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"
	"github.com/prepor/condo/top"
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

func Go() {
	app := cli.App("condo", "Reliable and simple idempotent supervisor for Docker containers")
	app.Version("version", humanVersion)

	auths := dockerAuths{}
	app.VarOpt("docker-auth", &auths, "Docker registry host:login:password")

	verbose := app.BoolOpt("verbose", false, "Enable debug logs")

	app.Spec = "[--docker-auth]... [--verbose]"

	app.Before = func() {
		if *verbose {
			log.SetLevel(log.DebugLevel)
		}
	}

	app.Command("execute", "Start docker container from provided EDN spec", func(cmd *cli.Cmd) {
		specPath := cmd.StringArg("PATH", "", "")
		cmd.Action = func() {
			content, err := ioutil.ReadFile(*specPath)
			logger := log.WithField("path", *specPath)
			if err != nil {
				logger.WithError(err).Fatal("Can't read")
			}
			s, err := spec.Parse(content)
			if err != nil {
				logger.WithError(err).Fatal("Can't parse")
			}
			docker := docker.New(auths)
			name := filepath.Base(*specPath)
			container, err := docker.Start(log.NewEntry(log.StandardLogger()), name[0:len(name)-len(filepath.Ext(name))], s)
			if err != nil {
				logger.WithError(err).Fatal("Can't start container")
			}
			logger.WithField("id", container.Id).Info("Container started")
		}
	})

	app.Command("start", "Start condo daemon with specs provider", func(cmd *cli.Cmd) {
		directory := cmd.StringOpt("directory", "", "Path to directory with condo's specs")
		listen := cmd.StringOpt("listen", ":4765", "Provides HTTP API and dashboard")
		systemName := cmd.StringOpt("instance-name", "", "Id of this instance. Can be used in exposing")

		consulPrefix := cmd.StringOpt("expose-consul", "", "Expose state to consul with provided prefix")

		gossipEnable := cmd.BoolOpt("expose-gossip", false, "Annonce itself via gossip protocol")
		gossipConnects := cmd.StringsOpt("gossip-connect", []string{}, "Initial address for gossip membership")
		gossipBindAddr := cmd.StringOpt("gossip-bind-addr", "0.0.0.0", "Address to bind to")
		gossipBindPort := cmd.IntOpt("gossip-bind-port", 7946, "Port to bind to")

		gossipAdvAddr := cmd.StringOpt("gossip-adv-addr", "", "Address to advertise to other cluster members")
		gossipAdvPort := cmd.IntOpt("gossip-adv-port", 7946, "Port to advertise to other cluster members")

		apiAdvAddr := cmd.StringOpt("api-adv-addr", "", "Address of HTTP API to advertise to other cluster members")
		apiAdvPort := cmd.IntOpt("api-adv-port", 4765, "Address of HTTP API to advertise to other cluster members")

		cmd.Spec = "--directory=<path> [--listen=<addr>]" +
			"[--expose-consul=<prefix> | " +
			"[--expose-gossip --gossip-connect=<addr> [--gossip-bind-addr=<addr>] [--gossip-bind-port=<port>] [--gossip-adv-addr=<addr>] [--gossip-adv-port=<port>] [--api-adv-addr=<addr>] [--api-adv-port=<port>]]" +
			"]" +
			"[--instance-name=<name>]"
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

			if *systemName != "" {
				system.SetName(*systemName)
			}

			sup := supervisor.New(system)

			var httpApi *api.API
			if *listen != "" {
				httpApi = api.New(system, sup, *listen)
			}

			var exposer expose.Exposer

			if *consulPrefix != "" {
				exposer = consul.New(*consulPrefix)
			}

			if *gossipEnable {
				if *listen == "" {
					log.Fatal("Can't be part of gossip cluster without enabled HTTP API")
				}
				exposer = gossip.New(&gossip.Config{
					Condo:         system.Name(),
					Connects:      *gossipConnects,
					BindAddr:      *gossipBindAddr,
					BindPort:      *gossipBindPort,
					AdvertiseAddr: *gossipAdvAddr,
					AdvertisePort: *gossipAdvPort,
					ApiAddr:       *apiAdvAddr,
					ApiPort:       *apiAdvPort,
				})
			}

			if exposer != nil {
				expose.New(system, sup, exposer)
				if httpApi != nil {
					httpApi.SetExposer(exposer)
				}

			}
			sup.Start()

			<-sigs
			system.Stop()

		}
	})

	app.Command("top", "Show condo's status", func(cmd *cli.Cmd) {
		connect := cmd.StringOpt("connect", "ws://localhost:4765/v1/state-stream", "Condo daemon address")
		cmd.Spec = "[--connect=<addr>]"
		cmd.Action = func() {
			top.Go(*connect)
		}
	})

	app.Run(os.Args)
}
