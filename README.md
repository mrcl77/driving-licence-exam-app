# PrawoTest

A Rails app for practising the Polish driving licence theory exam. It mirrors
the official format: 32 questions (20 basic + 12 specialist), 25 minutes, and
68 out of 74 points to pass. Specialist questions depend on the licence
category you pick (A, B, C, and so on).

Each question runs on its own timer — 35 seconds for a basic question (the
official 20 s to read plus 15 s to answer), 50 seconds for a specialist one.
When the timer runs out, the question counts as wrong and the exam moves on.
You can't return to a closed question, same as the real exam.

The interface is available in Polish and English. Questions can be taken in
Polish, English, German or Ukrainian — attempts in a language other than
Polish only draw questions that are fully translated into it.

## Requirements

- Ruby (see `.ruby-version`)
- PostgreSQL

## Setup

```bash
bin/setup --skip-server
bin/rails server
```

`bin/setup` installs gems, prepares the database and clears old logs. Drop the
`--skip-server` flag if you want it to start the dev server for you.

The repository ships no question data. Until a question bank, an exam
blueprint and licence categories are loaded into the database, the start page
shows a "missing configuration" notice.

## Tests

```bash
bin/rails db:test:prepare test test:system
```

System tests use Capybara with Selenium, so you'll need a recent Chrome
installed.

## How it's organised

- **Question banks** hold the imported question pool. Only one bank is active
  at a time.
- **Exam blueprints** define the rules for an exam — how many questions of
  each weight and scope, duration, pass score.
- **Exam attempts** are the individual sessions. Each one freezes its set of
  questions at the moment it's built, so results stay reproducible even if
  the bank changes later. Attempts are addressed by UUID in the URL.

`ExamAttemptsController` drives the exam flow and `ExamAttemptBuilder` is
where a new attempt is assembled.
