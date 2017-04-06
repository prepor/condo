package instance

import (
	"fmt"
	"io"
)

const (
	white  = 7
	red    = 1
	green  = 2
	yellow = 3
)

func writeState(w io.Writer, x Snapshot, color int64) {
	fmt.Fprintf(w, "\033[3%dm%-15s\033[0m", color, x)
}

func (x *Init) String() string {
	return "Init"
}

func (x *Init) CliStatus(w io.Writer) {
	writeState(w, x, white)
}

func (x *Stopped) String() string {
	return "Stopped"
}

func (x *Stopped) CliStatus(w io.Writer) {
	writeState(w, x, white)
}

func (x *Wait) String() string {
	return "Wait"
}

func (x *Wait) CliStatus(w io.Writer) {
	writeState(w, x, yellow)
	fmt.Fprintf(w, "[->%s]", x.Container.Spec.Image())
}

func (x *WaitNext) String() string {
	return "WaitNext"
}

func (x *WaitNext) CliStatus(w io.Writer) {
	writeState(w, x, yellow)
	fmt.Fprintf(w, "[%s->%s]", x.Current.Spec.Image(), x.Next.Spec.Image())
}

func (x *TryAgain) String() string {
	return "TryAgain"
}

func (x *TryAgain) CliStatus(w io.Writer) {
	writeState(w, x, red)
	fmt.Fprintf(w, "[->%s]", x.Spec.Image())
}

func (x *TryAgainNext) String() string {
	return "TryAgainNext"
}

func (x *TryAgainNext) CliStatus(w io.Writer) {
	writeState(w, x, red)
	fmt.Fprintf(w, "[%s->%s]", x.Current.Spec.Image(), x.Spec.Image())
}

func (x *Stable) String() string {
	return "Stable"
}

func (x *Stable) CliStatus(w io.Writer) {
	writeState(w, x, green)
	fmt.Fprintf(w, "[%s]", x.Container.Spec.Image())
}

func (x *BothStarted) String() string {
	return "BothStarted"
}

func (x *BothStarted) CliStatus(w io.Writer) {
	writeState(w, x, green)
	fmt.Fprintf(w, "[%s->%s]", x.Prev.Spec.Image(), x.Next.Spec.Image())
}
