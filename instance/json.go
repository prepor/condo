package instance

import "encoding/json"

func (x *BothStarted) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		BothStarted
	}{"BothStarted", *x})
}

func (x *Stopped) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Stopped
	}{"Stopped", *x})
}

func (x *TryAgainNext) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		TryAgainNext
	}{"TryAgainNext", *x})
}

func (x *WaitNext) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		WaitNext
	}{"WaitNext", *x})
}

func (x *Stable) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Stable
	}{"Stable", *x})
}

func (x *TryAgain) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		TryAgain
	}{"TryAgain", *x})
}

func (x *Wait) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Wait
	}{"Wait", *x})
}

func (x *Init) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State string
		Init
	}{"Init", *x})
}
