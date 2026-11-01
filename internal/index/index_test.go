package index

import (
	"strconv"
	"strings"
	"testing"
)

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

func TestCountUniqueHandlesManyUnknownTokens(t *testing.T) {
	const tokenCount = 10000
	tokens := make([]string, 0, tokenCount+2)
	for i := range tokenCount {
		tokens = append(tokens, "unknown"+strconv.Itoa(i))
	}
	tokens = append(tokens, tokens[0], tokens[tokenCount-1])

	if got := countUnique(tokens); got != tokenCount {
		t.Fatalf("countUnique() = %d, want %d", got, tokenCount)
	}
}

func TestDottedKeyCollisionKeepsBothValuesDeterministically(t *testing.T) {
	content := []byte(`{"a.b":"Flat dotted value here","a":{"b":"Nested object value here"}}`)
	for range 20 {
		idx, err := FromBytes(content, 8)
		if err != nil {
			t.Fatal(err)
		}
		for _, value := range []string{"Flat dotted value here", "Nested object value here"} {
			if got := idx.Lookup(value); len(got) != 1 || got[0].Key != "a.b" || got[0].Value != value {
				t.Fatalf("Lookup(%q) = %#v, want key a.b", value, got)
			}
		}
	}
}

func TestMatchOrderIsStableAcrossLoads(t *testing.T) {
	content := []byte(`{"z":"Save changes","b":"Save changes","m":"Save changes",
		"greet.z":"Hello, {name}","greet.a":"Hello, {user}"}`)
	for range 20 {
		idx, err := FromBytes(content, 8)
		if err != nil {
			t.Fatal(err)
		}
		if got := keys(idx.Lookup("Save changes")); got != "b,m,z" {
			t.Fatalf("Lookup order = %s, want b,m,z", got)
		}
		if got := keys(idx.LookupPattern("Hello, Bob")); got != "greet.a,greet.z" {
			t.Fatalf("LookupPattern order = %s, want greet.a,greet.z", got)
		}
	}
}

func TestPlaceholderFreePluralBranchesMatchExactly(t *testing.T) {
	idx, err := FromBytes([]byte(`{"cart":"{count, plural, =0 {Your cart is empty} one {One item in cart} other {# items in cart}}"}`), 8)
	if err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct{ literal, variant string }{
		{"Your cart is empty", "Your cart is empty"},
		{"ONE ITEM IN CART", "One item in cart"},
	} {
		got := idx.Lookup(tt.literal)
		if len(got) != 1 || got[0].Key != "cart" || got[0].Variant != tt.variant {
			t.Fatalf("Lookup(%q) = %#v, want cart variant %q", tt.literal, got, tt.variant)
		}
	}
	// The placeholder branch stays a pattern match, not an exact one.
	if got := idx.Lookup("# items in cart"); len(got) != 0 {
		t.Fatalf("placeholder branch indexed exactly: %#v", got)
	}
	if got := idx.LookupPattern("3 items in cart"); len(got) != 1 {
		t.Fatalf("LookupPattern(3 items in cart) = %#v", got)
	}
}

func TestPluralBranchEdgeCases(t *testing.T) {
	idx, err := FromBytes([]byte(`{
		"short": "{n, plural, one {Tiny} other {Plenty of things}}",
		"nested": "{n, plural, one {Only {name} is here} other {Everyone is here now}}",
		"upper": "{n, plural, One {Capital selector text} other {Lower selector text}}",
		"same": "{n, plural, one {Identical branch text} other {Identical branch text}}",
		"bare": "{n, plural, = {Bare equals branch} other {Other branch text}}",
		"noicu": "Pick one {Not a plural branch} please"
	}`), 8)
	if err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		literal string
		want    int
	}{
		{"Tiny", 0},                  // below --min-length
		{"Plenty of things", 1},      // sibling branch still indexed
		{"Only {name} is here", 0},   // contains a placeholder: pattern only
		{"Everyone is here now", 1},  //
		{"Capital selector text", 0}, // "One" is not an ICU keyword
		{"Lower selector text", 1},   //
		{"Identical branch text", 1}, // deduplicated per key
		{"Bare equals branch", 0},    // "=" without a number is not a selector
		{"Other branch text", 1},     //
		{"Not a plural branch", 0},   // no plural keyword
	} {
		if got := idx.Lookup(tt.literal); len(got) != tt.want {
			t.Fatalf("Lookup(%q) = %#v, want %d matches", tt.literal, got, tt.want)
		}
	}
}

func TestHasExactValueAcceptsPluralVariant(t *testing.T) {
	matches := []Match{{Key: "cart", Value: "{count, plural, one {One item} other {# items}}", Variant: "One item"}}
	if !HasExactValue(matches, "One item") {
		t.Fatal("HasExactValue(variant) = false, want true")
	}
	if HasExactValue(matches, "one item") {
		t.Fatal("HasExactValue(case drift) = true, want false")
	}
}

func keys(matches []Match) string {
	out := make([]string, 0, len(matches))
	for _, match := range matches {
		out = append(out, match.Key)
	}
	return strings.Join(out, ",")
}

func TestPluralWordInProseIsNotAnICUValue(t *testing.T) {
	idx, err := FromBytes([]byte(`{
		"prose": "Use the plural form: one {apple} other {apples} here",
		"ordinal": "{place, selectordinal, one {You finished first} other {You finished #th}}"
	}`), 1)
	if err != nil {
		t.Fatal(err)
	}
	if got := idx.Lookup("apple"); len(got) != 0 {
		t.Fatalf("prose split into plural branches: %#v", got)
	}
	if got := idx.Lookup("You finished first"); len(got) != 1 {
		t.Fatalf("selectordinal branch not indexed: %#v", got)
	}
	if got := idx.LookupPattern("You finished 3th"); len(got) != 1 {
		t.Fatalf("selectordinal pattern not matched: %#v", got)
	}
}
