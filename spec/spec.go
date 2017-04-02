package spec

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/go-edn/edn"
	"github.com/mitchellh/mapstructure"
)

type IDeployStrategy interface {
	deployStrategy()
}

type DeployStrategy struct {
	Strategy IDeployStrategy
}

func deployStrategyError() error {
	return errors.New("Deploy strategy should be [:After int] or [:Before]")
}

func (s *DeployStrategy) UnmarshalEDN(bs []byte) error {
	var v []interface{}
	err := edn.Unmarshal(bs, &v)
	if err != nil {
		return err
	}
	if len(v) == 0 {
		return deployStrategyError()
	}
	t, ok := v[0].(edn.Keyword)
	if ok != true {
		return deployStrategyError()
	}

	if len(v) == 2 && t == edn.Keyword("After") {
		if i, i_ok := v[1].(int64); i_ok {
			*s = DeployStrategy{Strategy: After{Secs: i}}
			return nil
		} else {
			return deployStrategyError()
		}
	} else if len(v) == 1 && t == edn.Keyword("Before") {
		*s = DeployStrategy{Strategy: Before{}}
		return nil
	}
	return deployStrategyError()
}

type Spec struct {
	Deploy        DeployStrategy
	Spec          interface{}
	HealthTimeout int64 `edn:"health-timeout"`
	StopTimeout   int64 `edn:"stop-timeout"`
}

type After struct {
	Secs int64
}
type Before struct{}

func (s After) deployStrategy()  {}
func (s Before) deployStrategy() {}

func Parse(v []byte) (*Spec, error) {
	var s Spec
	s.Deploy = DeployStrategy{Strategy: Before{}}
	s.StopTimeout = 10
	s.HealthTimeout = 10
	if err := edn.Unmarshal(v, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func decodeConfig(from interface{}, to interface{}) error {
	decoder, err := mapstructure.NewDecoder(&mapstructure.DecoderConfig{
		ErrorUnused: true,
		Result:      to,
	})

	if err != nil {
		return err
	}

	err = decoder.Decode(from)
	if err != nil {
		return err
	}
	return nil
}

func (s *Spec) ContainerConfigs() (*container.Config, *container.HostConfig, *network.NetworkingConfig, error) {
	var (
		config           container.Config
		hostConfig       container.HostConfig
		networkingConfig network.NetworkingConfig
	)
	unspecific, ok := unspecifyEdn(s.Spec).(map[string]interface{})
	if ok != true {
		err := errors.New("Container spec should be map")
		return nil, nil, nil, err
	}
	hostConfigRaw := unspecific["HostConfig"]
	networkingConfigRaw := unspecific["NetworkingConfig"]
	delete(unspecific, "HostConfig")
	delete(unspecific, "NetworkingConfig")

	if err := decodeConfig(unspecific, &config); err != nil {
		return nil, nil, nil, err
	}

	if err := decodeConfig(hostConfigRaw, &hostConfig); err != nil {
		return nil, nil, nil, err
	}

	if err := decodeConfig(networkingConfigRaw, &networkingConfig); err != nil {
		return nil, nil, nil, err
	}
	return &config, &hostConfig, &networkingConfig, nil
}

func (x *Spec) IsAfter() bool {
	_, ok := x.Deploy.Strategy.(After)
	return ok
}

func (x *Spec) IsBefore() bool {
	_, ok := x.Deploy.Strategy.(Before)
	return ok
}

func (x *Spec) AfterTimeout() int64 {
	return x.Deploy.Strategy.(After).Secs
}

func ednToString(x interface{}) string {
	switch t := x.(type) {
	default:
		v, err := json.Marshal(t)
		if err != nil {
			panic(fmt.Sprintf("Can't marshal EDN to string: %#v", err))
		}
		return string(v)
	case edn.Keyword:
		return string(t)
	case edn.Symbol:
		return string(t)
	case edn.Tag:
		return ednToString(t.Value)
	}
}

func unspecifyEdn(x interface{}) interface{} {
	switch t := x.(type) {
	default:
		return t
	case map[interface{}]interface{}:
		m := make(map[string]interface{})
		for k, v := range t {
			m[ednToString(k)] = unspecifyEdn(v)
		}
		return m
	case []interface{}:
		xs := make([]interface{}, len(t))
		for _, v := range t {
			xs = append(xs, unspecifyEdn(v))
		}
		return xs
	case edn.Keyword:
		return string(t)
	case edn.Symbol:
		return string(t)
	case edn.Tag:
		return ednToString(t.Value)
	}
}
