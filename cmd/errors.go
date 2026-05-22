package cmd

import "errors"

type silentError struct {
	err error
}

func (e silentError) Error() string {
	return e.err.Error()
}

func (e silentError) Unwrap() error {
	return e.err
}

func alreadyPrinted(err error) error {
	return silentError{err: err}
}

// IsSilentError reports whether the command already wrote the error to stderr.
func IsSilentError(err error) bool {
	var target silentError
	return errors.As(err, &target)
}
