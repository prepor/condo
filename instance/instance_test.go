package instance

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"

	"github.com/prepor/condo/docker"
	"github.com/prepor/condo/system"
	"github.com/stretchr/testify/require"
)

func makeFile(t *testing.T, dir string, s string) {
	tmpfn := filepath.Join(dir, "spec1.edn")
	err := ioutil.WriteFile(tmpfn, []byte(s), 0666)
	require.Nil(t, err)
}

func testPrepare(t *testing.T) (string, *Instance, <-chan Snapshot) {
	dir, err := ioutil.TempDir("", "watchspecs")
	require.Nil(t, err)

	docker := docker.New(nil)
	specs := system.NewDirectorySpecs(dir)
	system := system.New(docker, specs)

	instance := New(system, "spec1")

	snapshots := instance.AddSubsriber("tests")
	return dir, instance, snapshots
}

func TestBasicHealthy(t *testing.T) {
	dir, instance, snapshots := testPrepare(t)
	defer os.RemoveAll(dir)

	instance.Start()

	makeFile := func(s string) {
		tmpfn := filepath.Join(dir, "spec1.edn")
		err := ioutil.WriteFile(tmpfn, []byte(s), 0666)
		require.Nil(t, err)
	}

	makeFile(`{:spec {:Image "prepor/condo-test:good"}}`)
	require.IsType(t, new(Wait), <-snapshots)
	require.IsType(t, new(Stable), <-snapshots)

	go instance.Stop()

	require.IsType(t, new(Stopped), <-snapshots)
}

func TestBasicUnhealthy(t *testing.T) {
	dir, instance, snapshots := testPrepare(t)
	defer os.RemoveAll(dir)
	instance.Start()

	make := func(s string) { makeFile(t, dir, s) }

	make(`{:spec {:Image "prepor/condo-test:unknown"}}`)
	require.IsType(t, new(TryAgain), <-snapshots)
	require.IsType(t, new(TryAgain), <-snapshots)
	make(`{:spec {:Image "prepor/condo-test:bad"}}`)
	require.IsType(t, new(Wait), <-snapshots)

	go instance.Stop()

	require.IsType(t, new(Stopped), <-snapshots)
}

func TestComplex1(t *testing.T) {
	dir, instance, snapshots := testPrepare(t)
	defer os.RemoveAll(dir)

	instance.Start()

	make := func(s string) { makeFile(t, dir, s) }

	make(`{:spec {:Image "prepor/condo-test:good"}
           :deploy [:After 2]}`)
	require.IsType(t, new(Wait), <-snapshots)
	require.IsType(t, new(Stable), <-snapshots)

	make(`{:spec {:Image "prepor/condo-test:good2"}
           :deploy [:After 2]}`)
	require.IsType(t, new(WaitNext), <-snapshots)
	require.IsType(t, new(BothStarted), <-snapshots)
	require.IsType(t, new(Stable), <-snapshots)

	go instance.Stop()

	require.IsType(t, new(Stopped), <-snapshots)
}

func TestComplex2(t *testing.T) {
	dir, instance, snapshots := testPrepare(t)
	defer os.RemoveAll(dir)

	instance.Start()

	make := func(s string) { makeFile(t, dir, s) }

	make(`{:spec {:Image "prepor/condo-test:good"}
           :deploy [:After 2]}`)
	require.IsType(t, new(Wait), <-snapshots)
	require.IsType(t, new(Stable), <-snapshots)

	make(`{:spec {:Image "prepor/condo-test:unknown"}
           :deploy [:After 2]}`)
	require.IsType(t, new(TryAgainNext), <-snapshots)
	require.IsType(t, new(TryAgainNext), <-snapshots)

	make(`{:spec {:Image "prepor/condo-test:bad"}
           :deploy [:After 2]}`)
	require.IsType(t, new(WaitNext), <-snapshots)
	require.IsType(t, new(TryAgainNext), <-snapshots)
	require.IsType(t, new(WaitNext), <-snapshots)
	require.IsType(t, new(TryAgainNext), <-snapshots)

	go instance.Stop()

	require.IsType(t, new(Stopped), <-snapshots)
}
