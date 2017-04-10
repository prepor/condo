package consul

import (
	"bytes"
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Jeffail/gabs"
	consul "github.com/hashicorp/consul/api"
	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/expose"
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"
	"github.com/stretchr/testify/require"
)

type testInstance struct {
	instance  *instance.Instance
	snapshots <-chan instance.Snapshot
}

func testPrepare(t *testing.T) (string, *system.System, *supervisor.Supervisor, chan *testInstance) {
	dir, err := ioutil.TempDir("", "consul")
	require.Nil(t, err)

	docker := docker.New(nil)
	specs := system.NewDirectorySpecs(dir)
	system := system.New(docker, specs)
	system.SetName("test")

	supervisor := supervisor.New(system)
	testInstances := make(chan *testInstance)
	instances := supervisor.Subscribe("test")

	go func() {
		for {
			i, ok := <-instances
			if !ok {
				break
			}
			snapshots := i.Subsribe("test")
			testInstances <- &testInstance{
				instance:  i,
				snapshots: snapshots,
			}
		}
	}()
	return dir, system, supervisor, testInstances
}

func makeFile(t *testing.T, dir string, file string, s string) {
	tmpfn := filepath.Join(dir, file)
	err := ioutil.WriteFile(tmpfn, []byte(s), 0666)
	require.Nil(t, err)
}

func watchKey(t *testing.T, client *consul.Client, k string) <-chan *gabs.Container {
	kv := client.KV()
	res := make(chan *gabs.Container)
	var (
		v         *consul.KVPair
		meta      *consul.QueryMeta
		prevValue = []byte("---init---")
		err       error
		options   = &consul.QueryOptions{}
	)
	go func() {
		for {
			v, meta, err = kv.Get(k, options)
			if err != nil {
				time.Sleep(100 * time.Millisecond)
				continue
			}

			options.WaitIndex = meta.LastIndex

			if v == nil {
				if prevValue != nil {
					res <- nil
				}
				prevValue = nil
				continue
			}

			if !bytes.Equal(v.Value, prevValue) {
				c, err := gabs.ParseJSON(v.Value)
				require.NoError(t, err)
				res <- c
				prevValue = v.Value
			}

		}
	}()
	return res
}

func TestBasicCase(t *testing.T) {
	dir, system, supervisor, instances := testPrepare(t)
	defer os.RemoveAll(dir)

	supervisor.Start()

	makeFile(t, dir, "spec1.edn",
		`{:spec {:Image "consul:0.8.0"
                         :HostConfig {:PortBindings {"8500/tcp" [{:HostPort "8500"}]}}}}`)

	consul := <-instances
	require.IsType(t, new(instance.Wait), <-consul.snapshots)
	require.IsType(t, new(instance.Stable), <-consul.snapshots)

	exposer := New("condo")
	expose.New(system, supervisor, exposer)

	kWatcher := watchKey(t, exposer.client, "condo/test/nginx")

	require.Nil(t, <-kWatcher)

	makeFile(t, dir, "nginx.edn", `{:spec {:Image "prepor/condo-test:good"}}`)

	nginx := <-instances
	require.IsType(t, new(instance.Wait), <-nginx.snapshots)
	require.IsType(t, new(instance.Stable), <-nginx.snapshots)
Loop:
	for {
		switch (<-kWatcher).Path("State").Data().(string) {
		case "Stable":
			break Loop
		case "Wait":
			continue Loop
		default:
			t.FailNow()
		}
	}

	states := <-exposer.ReceiveStates(nil)
	require.Equal(t, 1, len(states))
	c, err := gabs.Consume(states[0].Snapshot)
	require.NoError(t, err)
	require.Equal(t, "Stable", c.S("State").Data().(string))

	os.Remove(filepath.Join(dir, "nginx.edn"))
	require.IsType(t, new(instance.Stopped), <-nginx.snapshots)
	require.Nil(t, <-kWatcher)
	go system.Stop()

	require.IsType(t, new(instance.Stopped), <-consul.snapshots)

}
