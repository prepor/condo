package api

import (
	"encoding/json"

	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/supervisor"
)

type stateManager struct {
	readRequests      chan chan<- map[string]instance.Snapshot
	readStreams       chan chan<- *StreamAnswer
	closedReadStreams chan chan<- *StreamAnswer
}

type clbKeyType string

var clbKey = clbKeyType("api-state-manager")

type newSnapshot struct {
	name     string
	snapshot instance.Snapshot
}

func newStateManager(supervisor *supervisor.Supervisor) *stateManager {
	readRequests := make(chan chan<- map[string]instance.Snapshot)
	readStreams := make(chan chan<- *StreamAnswer)
	closedReadStreams := make(chan chan<- *StreamAnswer)
	streams := make([]chan<- *StreamAnswer, 0)
	instances := make(map[string]instance.Snapshot)
	newInstances := make(chan *instance.Instance)
	removedInstances := make(chan *instance.Instance)
	snapshots := make(chan *newSnapshot)

	supervisor.RegisterNewCallback(clbKey, func(i *instance.Instance) {
		newInstances <- i
	})

	go func() {
		for {
			select {
			case i := <-newInstances:
				instances[i.Name] = &instance.Init{}
				iSnapshots := i.AddSubsriber(clbKey)
				go func() {
					for {
						s, ok := <-iSnapshots
						if ok {
							snapshots <- &newSnapshot{
								name:     i.Name,
								snapshot: s,
							}
						} else {
							removedInstances <- i
							break
						}
					}
				}()
			case i := <-removedInstances:
				delete(instances, i.Name)
			case s := <-snapshots:
				instances[s.name] = s.snapshot
				for _, stream := range streams {
					stream <- &StreamAnswer{
						Name:     s.name,
						Snapshot: s.snapshot,
					}
				}
			case r := <-readRequests:
				a := make(map[string]instance.Snapshot)
				for k, v := range instances {
					a[k] = v
				}
				r <- a
			case r := <-readStreams:
				for k, v := range instances {
					r <- &StreamAnswer{
						Name:     k,
						Snapshot: v,
					}
				}
				streams = append(streams, r)
			case s := <-closedReadStreams:
				newStreams := streams[:0]
				for _, x := range streams {
					if x != s {
						newStreams = append(newStreams, x)
					} else {
						close(x)
					}
				}
				streams = newStreams
			}
		}

	}()

	return &stateManager{
		readRequests:      readRequests,
		readStreams:       readStreams,
		closedReadStreams: closedReadStreams,
	}
}

func (x *stateManager) readCurrent() map[string]instance.Snapshot {
	a := make(chan map[string]instance.Snapshot)
	x.readRequests <- a
	return <-a
}

type StreamAnswer struct {
	Name     string
	Snapshot instance.Snapshot
}

func (x *StreamAnswer) UnmarshalJSON(bytes []byte) error {
	var data map[string]json.RawMessage
	if err := json.Unmarshal(bytes, &data); err != nil {
		return err
	}
	if err := json.Unmarshal(data["Name"], &x.Name); err != nil {
		return err
	}
	var s map[string]json.RawMessage
	if err := json.Unmarshal(data["Snapshot"], &s); err != nil {
		return err
	}
	var state string
	if err := json.Unmarshal(s["State"], &state); err != nil {
		return err
	}
	switch state {
	case "Init":
		var res instance.Init
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "Stable":
		var res instance.Stable
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "Wait":
		var res instance.Wait
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "TryAgain":
		var res instance.TryAgain
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "TryAgainNext":
		var res instance.TryAgainNext
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "WaitNext":
		var res instance.WaitNext
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "Stopped":
		var res instance.Stopped
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	case "BothStarted":
		var res instance.BothStarted
		json.Unmarshal(data["Snapshot"], &res)
		x.Snapshot = &res
	}
	return nil
}

func (x *stateManager) readStream(done <-chan struct{}) <-chan *StreamAnswer {
	a := make(chan *StreamAnswer)
	x.readStreams <- a
	go func() {
		<-done
		x.closedReadStreams <- a
	}()
	return a
}
