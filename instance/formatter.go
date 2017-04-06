package instance

func (x *Init) String() string {
	return "Init"
}

func (x *Stopped) String() string {
	return "Stopped"
}

func (x *Wait) String() string {
	return "Wait"
}

func (x *WaitNext) String() string {
	return "WaitNext"
}

func (x *TryAgain) String() string {
	return "TryAgain"
}

func (x *TryAgainNext) String() string {
	return "TryAgainNext"
}

func (x *Stable) String() string {
	return "Stable"
}

func (x *BothStarted) String() string {
	return "BothStarted"
}
