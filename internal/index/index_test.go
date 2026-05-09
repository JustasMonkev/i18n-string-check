package index

import "testing"

func TestIndexCreationAndLookup(t *testing.T) {
	idx, err := FromBytes([]byte(`{"login.button":"Sign in","common.cancel":"Cancel"}`), 8)
	if err != nil {
		t.Fatal(err)
	}

	matches := idx.Lookup("sign in")
	if len(matches) != 1 {
		t.Fatalf("Lookup() returned %d matches, want 1", len(matches))
	}
	if matches[0].Key != "login.button" || matches[0].Value != "Sign in" {
		t.Fatalf("Lookup() = %#v", matches[0])
	}
}

func TestDuplicateValuesMapToMultipleKeys(t *testing.T) {
	idx, err := FromBytes([]byte(`{"common.save":"Save","profile.save":"Save"}`), 1)
	if err != nil {
		t.Fatal(err)
	}

	matches := idx.Lookup("SAVE")
	if len(matches) != 2 {
		t.Fatalf("Lookup() returned %d matches, want 2", len(matches))
	}
}

func TestHasExactValue(t *testing.T) {
	matches := []Match{
		{Key: "login.button", Value: "sign in"},
		{Key: "login.heading", Value: "Sign In"},
	}
	if !HasExactValue(matches, "sign in") {
		t.Fatal("HasExactValue() = false, want true")
	}
	if HasExactValue(matches, "Sign in") {
		t.Fatal("HasExactValue() = true, want false")
	}
}

func TestLookupSimilarFindsLikelyPreviousTranslationValue(t *testing.T) {
	idx, err := FromBytes([]byte(`{"login.title":"Hello my name is Justas, And I am Human, I am QA too"}`), 8)
	if err != nil {
		t.Fatal(err)
	}

	matches := idx.LookupSimilar("Hello my name is Justas, And I am Human")
	if len(matches) != 1 || matches[0].Key != "login.title" {
		t.Fatalf("LookupSimilar() = %#v", matches)
	}
	if matches[0].Score < 0.8 {
		t.Fatalf("Score = %v, want >= 0.8", matches[0].Score)
	}
	if matches[0].Why != "source string is contained in the current translation value; 82% word overlap" {
		t.Fatalf("Why = %q", matches[0].Why)
	}
}

func TestLookupSimilarUsesEditSimilarityForSmallWordChanges(t *testing.T) {
	idx, err := FromBytes([]byte(`{"dashboard.title":"Review consumer billing dashbord status today"}`), 8)
	if err != nil {
		t.Fatal(err)
	}

	matches := idx.LookupSimilar("Review customer billing dashboard status today")
	if len(matches) != 1 || matches[0].Key != "dashboard.title" {
		t.Fatalf("LookupSimilar() = %#v", matches)
	}
	if matches[0].Reason != "edit-similarity" {
		t.Fatalf("Reason = %q, want edit-similarity", matches[0].Reason)
	}
}

func TestLookupSimilarIgnoresShortDifferentStrings(t *testing.T) {
	idx, err := FromBytes([]byte(`{"login.button":"Log in"}`), 8)
	if err != nil {
		t.Fatal(err)
	}

	if matches := idx.LookupSimilar("Sign in"); len(matches) != 0 {
		t.Fatalf("LookupSimilar() = %#v, want no matches", matches)
	}
}

func TestLookupSimilarFindsMatchInLargeUnrelatedIndex(t *testing.T) {
	content := `{
		"noise.1": "The deployment pipeline finished without errors this morning",
		"noise.2": "Customers can export invoices from the billing settings page",
		"noise.3": "Administrators may revoke access tokens from user profiles",
		"login.title": "Hello my name is Justas, And I am Human, I am QA too"
	}`
	idx, err := FromBytes([]byte(content), 8)
	if err != nil {
		t.Fatal(err)
	}

	matches := idx.LookupSimilar("Hello my name is Justas, And I am Human")
	if len(matches) != 1 || matches[0].Key != "login.title" {
		t.Fatalf("LookupSimilar() = %#v, want login.title", matches)
	}
}

func TestShortValuesIgnored(t *testing.T) {
	idx, err := FromBytes([]byte(`{"short.ok":"OK"}`), 8)
	if err != nil {
		t.Fatal(err)
	}

	if got := idx.Lookup("OK"); len(got) != 0 {
		t.Fatalf("Lookup() returned %d matches, want 0", len(got))
	}
}

func TestNestedObjectsFlattenToDotKeys(t *testing.T) {
	idx, err := FromBytes([]byte(`{"login":{"button":"Sign in","title":"Welcome back"},"common":{"actions":{"save":"Save changes"}}}`), 1)
	if err != nil {
		t.Fatal(err)
	}

	for _, tt := range []struct {
		value string
		key   string
	}{
		{value: "Sign in", key: "login.button"},
		{value: "Welcome back", key: "login.title"},
		{value: "Save changes", key: "common.actions.save"},
	} {
		matches := idx.Lookup(tt.value)
		if len(matches) != 1 || matches[0].Key != tt.key {
			t.Fatalf("Lookup(%q) = %#v, want key %q", tt.value, matches, tt.key)
		}
	}
}
