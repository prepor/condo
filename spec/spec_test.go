package spec

import (
	"testing"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/go-edn/edn"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParsing(t *testing.T) {
	s := `{:deploy [:After 10]
	       :spec {:Image "nginx"
		      :HostConfig {:NetworkMode "host"}
		      :Env ["HOST=localhost"]}
	       :stop-timeout 5}`
	spec, err := Parse([]byte(s))
	if err != nil {
		t.Error("Spec parsing error: ", err)
	}

	assert.Equal(t,
		&Spec{Deploy: DeployStrategy{Strategy: After{Secs: 10}},
			Spec: map[interface{}]interface{}{
				edn.Keyword("Image"): "nginx",
				edn.Keyword("HostConfig"): map[interface{}]interface{}{
					edn.Keyword("NetworkMode"): "host",
				},
				edn.Keyword("Env"): []interface{}{
					"HOST=localhost",
				},
			},
			HealthTimeout: 10,
			StopTimeout:   5},
		spec)

	config, hostConfig, networkingConfig, err := spec.ContainerConfigs()

	assert.Equal(t, err, nil)
	assert.Equal(t, &container.Config{
		Image: "nginx",
		Env:   []string{"HOST=localhost"},
	},
		config)
	assert.Equal(t, &container.HostConfig{
		NetworkMode: "host",
	},
		hostConfig)
	assert.Equal(t, &network.NetworkingConfig{}, networkingConfig)

}

func TestConversion(t *testing.T) {
	var data interface{}
	s := `{:foo "1"
               "bar" "2"
               5 "5"}`
	err := edn.Unmarshal([]byte(s), &data)
	require.NoError(t, err)

	assert.Equal(t,
		map[interface{}]interface{}{
			edn.Keyword("foo"): "1",
			"bar":              "2",
			int64(5):           "5"},
		data)

	assert.Equal(t,
		map[string]interface{}{
			"foo": "1",
			"bar": "2",
			"5":   "5"},
		unspecifyEdn(data))

}
