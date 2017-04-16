package docker

import (
	"testing"

	"github.com/Sirupsen/logrus"
	"github.com/prepor/condo/spec"
	"github.com/stretchr/testify/require"
)

func makeLogger() *logrus.Entry {
	return logrus.StandardLogger().WithField("instance", "test")
}

var logger = makeLogger()

var docker = New(nil)

func TestStart(t *testing.T) {
	s := `{:spec {:Image "prepor/condo-test:good"}
         :health-timeout 10}`
	spec, err := spec.Parse([]byte(s))
	require.Nil(t, err)

	container, err := docker.Start(logger, "my_first", spec)

	require.NotNil(t, container)
	require.Nil(t, err)

	container.Stop()
}
