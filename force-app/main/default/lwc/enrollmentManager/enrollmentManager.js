import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCourses from '@salesforce/apex/EnrollmentManagerController.getCourses';
import getMatrix from '@salesforce/apex/EnrollmentManagerController.getMatrix';
import saveChanges from '@salesforce/apex/EnrollmentManagerController.saveChanges';

/**
 * Home page component of the ACME ESCMS app.
 * The manager picks a course; the component shows one row per employee and one column per
 * session of the next 3 months. Ticking a box enrolls, unticking cancels.
 * All business rules are enforced on the server (trigger + validation rules).
 */
export default class EnrollmentManager extends LightningElement {
    courseOptions = [];
    selectedCourseId;
    sessions = [];
    rows = [];
    isLoading = false;
    errorMessage;
    matrixLoaded = false;
    pendingCount = 0;
    pending = new Map(); // key -> { employeeId, sessionId, enrolled }

    @wire(getCourses)
    wiredCourses({ data, error }) {
        if (data) {
            this.courseOptions = data.map((course) => ({
                label: course.Topic__c ? `${course.Name} (${course.Topic__c})` : course.Name,
                value: course.Id
            }));
        } else if (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    get showTable() {
        return this.matrixLoaded && this.sessions.length > 0 && this.rows.length > 0;
    }

    get showNoSessions() {
        return this.matrixLoaded && this.sessions.length === 0;
    }

    get showNoEmployees() {
        return this.matrixLoaded && this.sessions.length > 0 && this.rows.length === 0;
    }

    get saveDisabled() {
        return this.isLoading || this.pendingCount === 0;
    }

    handleCourseChange(event) {
        this.selectedCourseId = event.detail.value;
        this.loadMatrix();
    }

    async loadMatrix() {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.pending = new Map();
        this.pendingCount = 0;
        try {
            const matrix = await getMatrix({ courseId: this.selectedCourseId });
            this.sessions = matrix.sessions.map((session) => ({
                ...session,
                subtitle:
                    `${session.venueName} | ${session.seatsLeft} of ${session.capacity} seats left` +
                    (session.frozen ? ' | locked (starts within 24h)' : '')
            }));
            this.rows = matrix.employees.map((employee) => {
                const enrolled = new Set(employee.enrolledSessionIds);
                return {
                    employeeId: employee.employeeId,
                    name: employee.name,
                    cells: matrix.sessions.map((session) => {
                        const checked = enrolled.has(session.sessionId);
                        return {
                            key: `${employee.employeeId}-${session.sessionId}`,
                            employeeId: employee.employeeId,
                            sessionId: session.sessionId,
                            label: `Enroll ${employee.name} in ${session.name}`,
                            checked,
                            original: checked,
                            // Frozen sessions are read-only; full sessions accept no new ticks.
                            disabled: session.frozen || (!checked && session.seatsLeft <= 0)
                        };
                    })
                };
            });
            this.matrixLoaded = true;
        } catch (error) {
            this.matrixLoaded = false;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleToggle(event) {
        const { employeeId, sessionId } = event.target.dataset;
        const checked = event.target.checked;
        const key = `${employeeId}-${sessionId}`;
        let original = false;

        this.rows = this.rows.map((row) => {
            if (row.employeeId !== employeeId) {
                return row;
            }
            return {
                ...row,
                cells: row.cells.map((cell) => {
                    if (cell.sessionId !== sessionId) {
                        return cell;
                    }
                    original = cell.original;
                    return { ...cell, checked };
                })
            };
        });

        if (checked === original) {
            this.pending.delete(key); // back to the saved state: nothing to do
        } else {
            this.pending.set(key, { employeeId, sessionId, enrolled: checked });
        }
        this.pendingCount = this.pending.size;
    }

    async handleSave() {
        this.isLoading = true;
        try {
            await saveChanges({ changesJson: JSON.stringify(Array.from(this.pending.values())) });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Enrollments saved',
                    message: 'The employees receive an email with the session details.',
                    variant: 'success'
                })
            );
            await this.loadMatrix();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Nothing was saved',
                    message: this.reduceError(error),
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.isLoading = false;
        }
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}