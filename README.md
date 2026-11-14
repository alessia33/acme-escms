# ACME ESCMS - Employee Soft Skills and Communication Course System

A Salesforce solution for ACME's internal training programme. Trainers create courses and
schedule sessions, managers enroll the employees who report to them, and the system protects
venue capacity, prevents time conflicts, freezes changes 24 hours before a session, sends
emails and reports finished courses to an external HR system.

The solution was built and tested in a Salesforce Developer Edition org. This repository holds
its metadata in Salesforce DX source format (API version 62.0).

## What is in this repository

| Path | Content |
| --- | --- |
| `force-app/main/default/objects` | 5 custom objects with their fields, validation rules and sharing model: Venue, Course, Employee, Training Session, Enrollment |
| `force-app/main/default/flows` | Record-triggered flow that makes the manager the owner of an employee record |
| `force-app/main/default/permissionsets` | `ACME_Trainer`, `ACME_Manager`, `ACME_HR_Integration` |
| `force-app/main/default/triggers` | One logic-free trigger per object (Training Session, Enrollment, Course) |
| `force-app/main/default/classes` | 9 Apex classes and 6 test classes (29 unit tests) |
| `force-app/main/default/lwc` | `enrollmentManager`, the home page component for managers |
| `force-app/main/default/applications`, `flexipages`, `tabs` | The Lightning app "ACME ESCMS", its home page and the object tabs |
| `manifest/package.xml` | List of all components of the solution |

## How each requirement is solved

| # | Requirement | Solution |
| --- | --- | --- |
| 1 | Trainers create courses and create or cancel sessions | Objects Course and Training Session, permission set `ACME_Trainer`. Cancelling a session cancels its enrollments (`TrainingSessionTriggerHandler`). |
| 2 | Managers enroll or cancel only their own employees | Employee is private and owned by the manager (flow). `EnrollmentTriggerHandler` rejects enrollments for employees of another manager. |
| 3 | Session size limited by the venue, no changes 24 hours before start | Capacity check in Apex with a row lock on the session; two validation rules for the 24-hour freeze. |
| 4 | Confirmation and cancellation emails | `EnrollmentEmailService`, one bulk send per transaction. |
| 5 | Weekly schedule for trainers on Monday | `TrainerWeeklyScheduleJob` (Schedulable, Mondays 07:00). |
| 6 | App "ACME ESCMS" with a custom home page | Lightning app, Lightning home page and the component `enrollmentManager`: course picklist, table of employees by sessions of the next 3 months, check boxes. |
| 7 | Send completed courses to an external HR system | `CourseCompletionJob` (nightly) and `CourseTriggerHandler` queue `HRSyncQueueable`, which posts JSON to the Named Credential `HR_System` and stores the result on the course. |

Further rules from the brief: trainers see only the enrollments of sessions they teach
(Enrollment is private; `EnrollmentSharingService` shares it with the trainer), employees and
trainers cannot have overlapping sessions (checked in the two trigger handlers).

## Security model

- Organization-wide defaults: Venue, Course and Training Session are Public Read Only;
  Employee and Enrollment are Private.
- Access is granted by permission sets, not by profiles.
- Classes that enforce business rules run `without sharing`; the controller of the home page
  component runs `with sharing` and in user mode.

## How to review in the org

- The demo users Tina Trainer and Mark Manager show what a trainer and a manager see:
  Setup > Users > Login next to the user.
- The manager-only rule has no exception for administrators. To enroll employees as yourself,
  create an Employee record with yourself as Manager, or log in as Mark Manager.
- Run the tests: Setup > Apex Test Execution > Select Tests, or the command below.

## Not stored in this repository

| Item | Why | How to recreate |
| --- | --- | --- |
| Named Credential and External Credential `HR_System` | They hold the address of the HR endpoint | Setup > Named Credentials. External Credential `HR_System` (No Authentication) with principal `HR_System_Principal`; Named Credential `HR_System` with the URL of the HR system. |
| Scheduled jobs | They are data, not metadata | Run the two lines below in Execute Anonymous. |
| Users, permission set assignments, demo data | They belong to one org | Assign the three permission sets to the right users. |
| Email deliverability | Org setting | Setup > Deliverability > Access level "All email". |

    System.schedule('ACME Weekly Trainer Schedule', '0 0 7 ? * MON', new TrainerWeeklyScheduleJob());
    System.schedule('ACME Daily Course Completion', '0 0 1 * * ?', new CourseCompletionJob());

## Commands

Connect the project to an org, deploy and run all tests:

    sf org login web --alias acme --set-default
    sf project deploy start --source-dir force-app
    sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 20

In an org other than the one this solution was built in, create the External Credential and
the Named Credential first, because the permission set `ACME_HR_Integration` refers to them.

Copy the components built in Setup from the org into this project:

    sf project retrieve start --manifest manifest/package.xml


