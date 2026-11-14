   System.schedule('ACME Weekly Trainer Schedule', '0 0 7 ? * MON', new TrainerWeeklyScheduleJob());
   System.schedule('ACME Daily Course Completion', '0 0 1 * * ?', new CourseCompletionJob());