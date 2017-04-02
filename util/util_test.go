package util

import (
	"reflect"
	"testing"
)

func TestDiffStrings(t *testing.T) {
	type args struct {
		slice1 []string
		slice2 []string
	}
	tests := []struct {
		name        string
		args        args
		wantNew     []string
		wantRemoved []string
	}{
		{"empty", args{nil, nil}, nil, nil},
		{"case1",
			args{[]string{"foo", "bar", "bar2"}, []string{"zoo", "bar", "foo", "foo2"}},
			[]string{"zoo", "foo2"}, []string{"bar2"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotNew, gotRemoved := DiffStrings(tt.args.slice1, tt.args.slice2)
			if !reflect.DeepEqual(gotNew, tt.wantNew) {
				t.Errorf("DiffStrings() gotNew = %v, want %v", gotNew, tt.wantNew)
			}
			if !reflect.DeepEqual(gotRemoved, tt.wantRemoved) {
				t.Errorf("DiffStrings() gotRemoved = %v, want %v", gotRemoved, tt.wantRemoved)
			}
		})
	}
}
