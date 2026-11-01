package main

import "testing"

func TestBuildInviteLink(t *testing.T) {
	link, err := buildInviteLink("https://music.example.com/base/?old=query", "ABCD-2345")
	if err != nil {
		t.Fatal(err)
	}
	if link != "https://music.example.com/base/invite#code=ABCD-2345" {
		t.Fatalf("unexpected invitation link: %s", link)
	}
}

func TestBuildInviteLinkAllowsUnsetDevelopmentURL(t *testing.T) {
	link, err := buildInviteLink("", "ABCD-2345")
	if err != nil || link != "" {
		t.Fatalf("expected no link and no error, got %q, %v", link, err)
	}
}

func TestBuildInviteLinkRejectsNonHTTPURL(t *testing.T) {
	if _, err := buildInviteLink("file:///tmp/music", "ABCD-2345"); err == nil {
		t.Fatal("expected invalid public URL error")
	}
}
