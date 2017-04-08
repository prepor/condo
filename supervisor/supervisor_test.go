package supervisor

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"

	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/system"
	"github.com/stretchr/testify/require"
)

func makeFile(t *testing.T, dir string, file string, s string) {
	tmpfn := filepath.Join(dir, file)
	err := ioutil.WriteFile(tmpfn, []byte(s), 0666)
	require.Nil(t, err)
}

type testInstance struct {
	instance  *instance.Instance
	snapshots <-chan instance.Snapshot
}

func testPrepare(t *testing.T) (string, *Supervisor, chan *testInstance) {
	dir, err := ioutil.TempDir("", "suervisor")
	require.Nil(t, err)

	docker := docker.New(nil)
	specs := system.NewDirectorySpecs(dir)
	system := system.New(docker, specs)

	supervisor := New(system)
	testInstances := make(chan *testInstance)
	instances := supervisor.Subscribe("test")

	go func() {
		for {
			i := <-instances
			snapshots := i.Subsribe("test")
			testInstances <- &testInstance{
				instance:  i,
				snapshots: snapshots,
			}
		}
	}()
	return dir, supervisor, testInstances
}

func TestSupervisor(t *testing.T) {
	dir, supervisor, instances := testPrepare(t)
	defer os.RemoveAll(dir)

	supervisor.Start()

	makeFile(t, dir, "spec1.edn", `{:spec {:Image "prepor/condo-test:good"}}`)

	instance1 := <-instances
	require.IsType(t, new(instance.Wait), <-instance1.snapshots)
	require.IsType(t, new(instance.Stable), <-instance1.snapshots)

	makeFile(t, dir, "spec2.edn", `{:spec {:Image "prepor/condo-test:good2"}}`)
	instance2 := <-instances
	require.IsType(t, new(instance.Wait), <-instance2.snapshots)
	require.IsType(t, new(instance.Stable), <-instance2.snapshots)

	os.Remove(filepath.Join(dir, "spec1.edn"))
	require.IsType(t, new(instance.Stopped), <-instance1.snapshots)

	go supervisor.system.Stop()

	require.IsType(t, new(instance.Stopped), <-instance2.snapshots)
}
