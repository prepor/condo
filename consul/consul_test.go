package consul

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Jeffail/gabs"
	"github.com/davecgh/go-spew/spew"
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
		v       *consul.KVPair
		meta    *consul.QueryMeta
		err     error
		options = &consul.QueryOptions{}
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
				res <- nil
				continue
			}
			spew.Dump(v)
			c, err := gabs.ParseJSON(v.Value)
			require.NoError(t, err)
			res <- c
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

	kWatcher := watchKey(t, exposer.client, "condo/Andrews-MacBook-Air.local/nginx")

	require.Nil(t, <-kWatcher)

	makeFile(t, dir, "nginx.edn", `{:spec {:Image "prepor/condo-test:good"}}`)

	nginx := <-instances
	require.IsType(t, new(instance.Wait), <-nginx.snapshots)
	require.Equal(t, "Wait", (<-kWatcher).Path("State").Data().(string))
	require.IsType(t, new(instance.Stable), <-nginx.snapshots)
	require.Equal(t, "Stable", (<-kWatcher).Path("State").Data().(string))
	os.Remove(filepath.Join(dir, "nginx.edn"))
	require.IsType(t, new(instance.Stopped), <-nginx.snapshots)
	require.Nil(t, <-kWatcher)

	go system.Stop()

	require.IsType(t, new(instance.Stopped), <-consul.snapshots)

}