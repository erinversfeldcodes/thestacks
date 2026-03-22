# Issue #099: Add Tests for ImageRetentionJob

## Summary
`ImageRetentionJob` is a GDPR-sensitive cron job (cleanup_stuck, cleanup_expired, missing_purge_check alarm) with no test file. It runs nightly and handles image retention policy enforcement.

## Goal
Add comprehensive tests for all three responsibilities of the job.

## Scope Check
- 1 new test file
- ~100 LOC

## Technical Requirements
- Test `cleanup_stuck`: images in "submitted" status older than retention period are expired
- Test `cleanup_expired`: expired images have their storage objects deleted
- Test `missing_purge_check`: images past purge deadline emit alarm event
- Test edge cases: no images to clean, already-cleaned images
- Use factory to create test images in various states

## Definition of Done
- [ ] All three job responsibilities tested
- [ ] Edge cases covered
- [ ] `just verify` passes

## Priority
P2 — fix during Wave E (GDPR-sensitive code should have tests)

## Agent Assignment
elixir-agent
