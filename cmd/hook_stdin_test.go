package cmd

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func scrubHookJSON(value interface{}) interface{} {
	switch v := value.(type) {
	case map[string]interface{}:
		for key, item := range v {
			if key == "tool_response" {
				v[key] = nil
			} else {
				v[key] = scrubHookJSON(item)
			}
		}
	case []interface{}:
		for i, item := range v {
			v[i] = scrubHookJSON(item)
		}
	case string:
		if len(v) > maxHookStringBytes {
			return ""
		}
	}
	return value
}

func TestHookStdinScannerPreservesJSONValues(t *testing.T) {
	padding, err := json.Marshal(strings.Repeat("p", maxHookStringBytes+1))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, value string
	}{
		{"escaped quotes and backslashes", `{"text":"a\\\"b\\\\c"}`},
		{"unicode escapes and surrogate pair", `{"text":"\u0041\uD83D\uDE00"}`},
		{"tool response in tool input", `{"tool_input":{"tool_response":{"secret":"example"},"command":"echo hello"}}`},
		{"tool response object", `{"tool_response":{"items":[1,true,null]}}`},
		{"tool response array", `{"tool_response":["example",{"nested":true}]}`},
		{"tool response string", `{"tool_response":"example"}`},
		{"tool response number", `{"tool_response":-1.25e+10}`},
		{"tool response null", `{"tool_response":null}`},
		{"tool response true", `{"tool_response":true}`},
		{"scalars", `{"negative":-12.5e-3,"positive":2E+4,"true":true,"false":false,"null":null}`},
		{"empty object and array", `{"object":{},"array":[]}`},
		{"whitespace", "{ \n \"one\" : [ true , null , -2.5e3 ] , \"two\" : { } }"},
		{"string exactly 65536 bytes", `{"text":"` + strings.Repeat("x", maxHookStringBytes) + `"}`},
		{"string 65537 bytes", `{"text":"` + strings.Repeat("x", maxHookStringBytes+1) + `"}`},
		{"escaped string exactly 65536 decoded bytes", `{"text":"` + strings.Repeat(`\u0061`, maxHookStringBytes) + `"}`},
		{"escaped string 65537 decoded bytes", `{"text":"` + strings.Repeat(`\u0061`, maxHookStringBytes+1) + `"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := []byte(`{"case":` + tc.value + `,"padding":` + string(padding) + `}`)
			if len(input) <= maxHookStringBytes {
				t.Fatal("fixture did not enter scanner path")
			}
			var original interface{}
			if err := json.Unmarshal(input, &original); err != nil {
				t.Fatalf("invalid fixture: %v", err)
			}
			want := scrubHookJSON(original)
			gotBytes, err := readStdinNonBlocking(strings.NewReader(string(input)))
			if err != nil {
				t.Fatalf("scan: %v", err)
			}
			var got interface{}
			if err := json.Unmarshal(gotBytes, &got); err != nil {
				t.Fatalf("invalid scanned JSON: %v", err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("decoded scanned JSON differs: got %s", gotBytes)
			}
		})
	}
}

func TestHookStdinScannerDepthAndTrailingData(t *testing.T) {
	padding := strings.Repeat("p", maxHookStringBytes+1)
	for _, tc := range []struct {
		name, value string
		wantError   string
	}{
		{"depth 64 accepted", strings.Repeat("[", maxHookDepth-1) + "0" + strings.Repeat("]", maxHookDepth-1), ""},
		{"depth 65 rejected", strings.Repeat("[", maxHookDepth) + "0" + strings.Repeat("]", maxHookDepth), "JSON nesting exceeds"},
		{"trailing data rejected", "0", "trailing data after JSON payload"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := `{"padding":"` + padding + `","value":` + tc.value + `}`
			if tc.name == "trailing data rejected" {
				input += " true"
			}
			if len(input) <= maxHookStringBytes {
				t.Fatal("fixture did not enter scanner path")
			}
			got, err := readStdinNonBlocking(strings.NewReader(input))
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("error = %v, want %q", err, tc.wantError)
				}
				return
			}
			if err != nil || !json.Valid(got) {
				t.Fatalf("depth 64: output=%q err=%v", got, err)
			}
			var original, scanned interface{}
			if err := json.Unmarshal([]byte(input), &original); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(got, &scanned); err != nil {
				t.Fatal(err)
			}
			if want := scrubHookJSON(original); !reflect.DeepEqual(scanned, want) {
				t.Fatalf("decoded scanned JSON differs: got %s", got)
			}
		})
	}
}
