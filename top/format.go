package top

import (
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/Jeffail/gabs"
	"github.com/nwidger/jsoncolor"
)

const (
	white  = 7
	red    = 1
	green  = 2
	yellow = 3
)

func writeState(w io.Writer, s string, color int64) {
	fmt.Fprintf(w, "\033[3%dm%-15s\033[0m", color, s)
}

func writeContainerDetails(w io.Writer, x *gabs.Container) {
	startedAt, err := time.Parse(
		time.RFC3339,
		x.Path("StartedAt").Data().(string))
	if err != nil {
		return
	}
	fmt.Fprint(w, "\n")
	fmt.Fprintf(w, "%s [%s]\n",
		x.Path("Id").Data().(string)[0:12],
		x.Path("Spec.Image").Data().(string))
	fmt.Fprintf(w, "%s running\n",
		time.Now().Round(time.Second).Sub(startedAt.Round(time.Second)))
	if x, err := json.Marshal(x.Path("Spec.Spec").Data()); err != nil {
		f := jsoncolor.NewFormatter()
		f.Format(w, x)
	}
}

func CliStatus(w io.Writer, s *gabs.Container) {
	state := s.Path("State").Data().(string)
	switch state {
	default:
		writeState(w, state, white)
	case "Wait":
		writeState(w, state, yellow)
		fmt.Fprintf(w, "[->%s]", s.Path("Container.Spec.Image").Data().(string))
	case "Stable":
		writeState(w, state, green)
		fmt.Fprintf(w, "[%s]",
			s.Path("Container.Spec.Image").Data().(string))
	case "WaitNext":
		writeState(w, state, yellow)
		fmt.Fprintf(w, "[%s->%s]",
			s.Path("Current.Spec.Image").Data().(string),
			s.Path("Next.Spec.Image").Data().(string))
	case "TryAgain":
		writeState(w, state, red)
		fmt.Fprintf(w, "[->%s]",
			s.Path("Spec.Image").Data().(string))
	case "TryAgainNext":
		writeState(w, state, red)
		fmt.Fprintf(w, "[%s->%s]",
			s.Path("Current.Spec.Image").Data().(string),
			s.Path("Spec.Image").Data().(string))
	case "BothStarted":
		writeState(w, state, green)
		fmt.Fprintf(w, "[%s->%s]",
			s.Path("Prev.Spec.Image").Data().(string),
			s.Path("Next.Spec.Image").Data().(string))
	}
}

func CliDetails(w io.Writer, s *gabs.Container) {
	state := s.Path("State").Data().(string)
	switch state {
	default:
		writeState(w, state, white)
	case "Wait":
		writeState(w, state, yellow)
		fmt.Fprint(w, "\n")
		writeContainerDetails(w, s.S("Container"))
	case "Stable":
		writeState(w, state, green)
		fmt.Fprint(w, "\n")
		writeContainerDetails(w, s.S("Container"))
	case "WaitNext":
		writeState(w, state, yellow)
		fmt.Fprint(w, "\n")
		writeContainerDetails(w, s.S("Current"))
		writeContainerDetails(w, s.S("Next"))
	case "TryAgain":
		writeState(w, state, red)
		fmt.Fprint(w, "\n")
	case "TryAgainNext":
		writeState(w, state, red)
		fmt.Fprint(w, "\n")
		writeContainerDetails(w, s.S("Current"))
	case "BothStarted":
		writeState(w, state, green)
		fmt.Fprint(w, "\n")
		writeContainerDetails(w, s.S("Prev"))
		writeContainerDetails(w, s.S("Next"))

	}
}
