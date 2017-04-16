package system

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-edn/edn"
	"github.com/prepor/condo/spec"
	"github.com/stretchr/testify/require"
)

func Test_directorySpecs_WatchSpecs(t *testing.T) {
	dir, err := ioutil.TempDir("", "watchspecs")
	require.Nil(t, err)
	defer os.RemoveAll(dir)

	watcher := NewDirectorySpecs(dir)
	done := make(chan struct{})

	specs := watcher.WatchSpecs(done)

	makeFile := func(s string) {
		tmpfn := filepath.Join(dir, s)
		err = ioutil.WriteFile(tmpfn, []byte(""), 0666)
		require.Nil(t, err)
	}

	makeFile("spec.edn")
	require.Equal(t, NewSpec{name: "spec"}, <-specs)

	makeFile("spec.json")
	makeFile("spec2.edn")
	require.Equal(t, NewSpec{name: "spec2"}, <-specs)

	os.Remove(filepath.Join(dir, "spec.edn"))

	require.Equal(t, RemovedSpec{name: "spec"}, <-specs)

	close(done)
	_, ok := <-specs
	require.False(t, ok)
}

func Test_directorySpecs_ReceiveSpecs(t *testing.T) {
	dir, err := ioutil.TempDir("", "watchspecs")
	require.Nil(t, err)
	defer os.RemoveAll(dir)

	watcher := NewDirectorySpecs(dir)
	done := make(chan struct{})

	updates := watcher.ReceiveSpecs("spec1", done)

	makeFile := func(s string) {
		tmpfn := filepath.Join(dir, "spec1.edn")
		err = ioutil.WriteFile(tmpfn, []byte(s), 0666)
		require.Nil(t, err)
	}

	makeFile("blala")

	makeFile(`{:spec {:Image "prepor/condo-test:good"}}`)
	require.Equal(t, &spec.Spec{Deploy: spec.DeployStrategy{Strategy: spec.Before{}},
		Spec: map[interface{}]interface{}{
			edn.Keyword("Image"): "prepor/condo-test:good",
		},
		StopTimeout: 10},
		<-updates)

	makeFile(`{:spec {:Image "prepor/condo-test:bad"}}`)
	require.Equal(t, &spec.Spec{Deploy: spec.DeployStrategy{Strategy: spec.Before{}},
		Spec: map[interface{}]interface{}{
			edn.Keyword("Image"): "prepor/condo-test:bad",
		},
		StopTimeout: 10},
		<-updates)

	close(done)
	_, ok := <-updates
	require.False(t, ok)
}
