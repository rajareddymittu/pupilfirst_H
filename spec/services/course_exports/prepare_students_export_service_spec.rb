require 'rails_helper'

describe CourseExports::PrepareStudentsExportService do
  include SubmissionsHelper

  subject { described_class.new(course_export) }

  let!(:course) { create :course }
  let(:cohort_live) { create :cohort, course: course }
  let(:cohort_ended) { create :cohort, course: course, ends_at: 1.day.ago }
  let(:level_1) { create :level, :one, course: course }
  let(:level_2) { create :level, :two, course: course }

  let(:user_1) do
    create :user, email: 'a@example.com', last_seen_at: 2.days.ago
  end

  let(:user_2) { create :user, email: 'b@example.com' }
  let(:user_3) { create :user, email: 'c@example.com' }
  let(:user_4) { create :user, email: 'd@example.com' }

  let(:student_1) do
    create :student,
           cohort: cohort_live,
           level: level_2,
           tag_list: ['tag 1', 'tag 2'],
           user: user_1
  end
  let!(:student_2) do
    create :student, cohort: cohort_live, level: level_1, user: user_2
  end

  let!(:student_3_access_ended) do
    create :student,
           cohort: cohort_ended,
           user: user_3,
           level: level_1,
           tag_list: ['tag 2']
  end

  let!(:student_4_dropped_out) do
    create :student,
           level: level_1,
           cohort: cohort_live,
           dropped_out_at: 1.day.ago,
           tag_list: ['tag 3'],
           user: user_4
  end

  let(:target_group_l1_non_milestone) do
    create :target_group, level: level_1, sort_index: 0
  end

  let(:target_group_l1_milestone) do
    create :target_group, level: level_1, milestone: true, sort_index: 1
  end

  let(:target_group_l2_milestone) do
    create :target_group, level: level_2, milestone: true, sort_index: 0
  end

  let!(:evaluation_criterion_1) do
    create :evaluation_criterion, course: course, name: 'Criterion A'
  end

  let!(:evaluation_criterion_2) do
    create :evaluation_criterion, course: course, name: 'Criterion B'
  end

  let!(:target_l1_evaluated) do
    create :target,
           target_group: target_group_l1_milestone,
           evaluation_criteria: [
             evaluation_criterion_1,
             evaluation_criterion_2
           ],
           sort_index: 1
  end

  let!(:target_l1_mark_as_complete) do
    create :target, target_group: target_group_l1_non_milestone
  end

  let!(:quiz) { create :quiz, target: target_l1_quiz }

  let!(:target_l1_quiz) do
    create :target, target_group: target_group_l1_milestone, sort_index: 0
  end

  let!(:target_l2_evaluated) do
    create :target,
           target_group: target_group_l2_milestone,
           evaluation_criteria: [evaluation_criterion_1]
  end

  let(:school) { course.school }
  let!(:school_admin) { create :school_admin, school: school }

  let(:course_export) do
    create :course_export, :students, course: course, user: school_admin.user
  end

  let!(:student_1_reviewed_submission) do
    complete_target target_l1_evaluated, student_1
  end

  let!(:student_2_reviewed_submission) do
    fail_target target_l1_evaluated, student_2
  end

  before do
    # First student has completed everything, but has a pending submission in L2.
    submit_target target_l1_mark_as_complete, student_1
    submission = submit_target target_l1_quiz, student_1
    submission.update!(quiz_score: '2/2')
    submit_target target_l2_evaluated, student_1

    # Second student is still on L1.
    submission = submit_target target_l1_quiz, student_2
    submission.update!(quiz_score: '1/2')

    # Student has an archived submission - data should not be present in the export
    create :timeline_event,
           :with_owners,
           latest: false,
           target: target_l1_evaluated,
           owners: [student_1],
           created_at: 3.days.ago,
           archived_at: 1.day.ago
  end

  def submission_grading(submission)
    submission
      .timeline_event_grades
      .joins(:evaluation_criterion)
      .order('evaluation_criteria.name')
      .pluck(:grade)
      .join(',')
  end

  def report_link_formula(student)
    {
      'formula' =>
        "oooc:=HYPERLINK(\"https://test.host/students/#{student.id}/report\"; \"#{student.id}\")"
    }
  end

  def last_seen_at(student)
    student.user.last_seen_at&.iso8601 || ''
  end

  let(:expected_data) do
    [
      {
        title: 'Targets',
        rows: [
          [
            'ID',
            "L1T#{target_l1_mark_as_complete.id}",
            "L1T#{target_l1_quiz.id}",
            "L1T#{target_l1_evaluated.id}",
            "L2T#{target_l2_evaluated.id}"
          ],
          ['Level', 1, 1, 1, 2],
          [
            'Name',
            target_l1_mark_as_complete.title,
            target_l1_quiz.title,
            target_l1_evaluated.title,
            target_l2_evaluated.title
          ],
          [
            'Completion Method',
            'Mark as Complete',
            'Take Quiz',
            'Graded',
            'Graded'
          ],
          %w[Milestone? No Yes Yes Yes],
          ['Students with submissions', 1, 2, 2, 1],
          ['Submissions pending review', 0, 0, 0, 1],
          [
            'Criterion A (2,3) - Average',
            nil,
            nil,
            (
              evaluation_criterion_1.timeline_event_grades.pluck(:grade).sum /
                2.0
            ).round(2).to_s,
            nil
          ],
          [
            'Criterion B (2,3) - Average',
            nil,
            nil,
            (
              evaluation_criterion_2.timeline_event_grades.pluck(:grade).sum /
                2.0
            ).round(2).to_s,
            nil
          ]
        ]
      },
      {
        title: 'Students',
        rows: [
          [
            'User ID',
            'Student ID',
            'Email Address',
            'Name',
            'Level',
            'Title',
            'Affiliation',
            'Tags',
            'Last Seen At',
            'Criterion A (2,3) - Average',
            'Criterion B (2,3) - Average'
          ],
          [
            student_1.user_id,
            report_link_formula(student_1),
            student_1.email,
            student_1.name,
            student_1.level.number,
            student_1.title,
            student_1.affiliation,
            'tag 1, tag 2',
            last_seen_at(student_1),
            student_1_reviewed_submission
              .timeline_event_grades
              .find_by(evaluation_criterion: evaluation_criterion_1)
              .grade
              .to_f
              .to_s,
            student_1_reviewed_submission
              .timeline_event_grades
              .find_by(evaluation_criterion: evaluation_criterion_2)
              .grade
              .to_f
              .to_s
          ],
          [
            student_2.user_id,
            report_link_formula(student_2),
            student_2.email,
            student_2.name,
            student_2.level.number,
            student_2.title,
            student_2.affiliation,
            '',
            last_seen_at(student_2),
            student_2_reviewed_submission
              .timeline_event_grades
              .find_by(evaluation_criterion: evaluation_criterion_1)
              .grade
              .to_f
              .to_s,
            student_2_reviewed_submission
              .timeline_event_grades
              .find_by(evaluation_criterion: evaluation_criterion_2)
              .grade
              .to_f
              .to_s
          ]
        ]
      },
      {
        title: 'Submissions',
        rows: [
          [
            'Student Email / Target ID',
            "L1T#{target_l1_mark_as_complete.id}",
            "L1T#{target_l1_quiz.id}",
            "L1T#{target_l1_evaluated.id}",
            "L2T#{target_l2_evaluated.id}"
          ],
          [
            student_1.email,
            '✓',
            '2/2',
            {
              'value' => submission_grading(student_1_reviewed_submission),
              'style' => 'passing-grade'
            },
            { 'value' => 'RP', 'style' => 'pending-grade' }
          ],
          [
            student_2.email,
            nil,
            '1/2',
            {
              'value' => submission_grading(student_2_reviewed_submission),
              'style' => 'failing-grade'
            }
          ]
        ]
      }
    ]
  end

  describe '#execute' do
    it 'exports data to an ODS file' do
      expect { subject.execute }.to change {
          course_export.reload.file.attached?
        }
        .from(false)
        .to(true)
      expect(course_export.file.filename.to_s).to end_with('.ods')
    end

    it 'stores data in JSON format' do
      subject.execute

      expect(JSON.parse(course_export.reload.json_data)).to be_an_object_like(
        expected_data
      )
    end

    context 'when course export data is customized using options' do
      let(:course_export) do
        create :course_export,
               :students,
               course: course,
               user: school_admin.user,
               reviewed_only: true,
               include_inactive_students: true,
               tag_list: ['tag 1', 'tag 2', 'tag 3']
      end

      before { submit_target target_l1_evaluated, student_1 }
      before { submit_target target_l1_evaluated, student_3_access_ended }
      before { submit_target target_l1_evaluated, student_4_dropped_out }

      let(:restricted_data) do
        [
          {
            title: 'Targets',
            rows: [
              [
                'ID',
                "L1T#{target_l1_evaluated.id}",
                "L2T#{target_l2_evaluated.id}"
              ],
              ['Level', 1, 2],
              ['Name', target_l1_evaluated.title, target_l2_evaluated.title],
              ['Completion Method', 'Graded', 'Graded'],
              %w[Milestone? Yes Yes],
              ['Students with submissions', 3, 1],
              ['Submissions pending review', 3, 1],
              [
                'Criterion A (2,3) - Average',
                student_1_reviewed_submission
                  .timeline_event_grades
                  .find_by(evaluation_criterion: evaluation_criterion_1)
                  .grade
                  .to_f
                  .to_s,
                nil
              ],
              [
                'Criterion B (2,3) - Average',
                student_1_reviewed_submission
                  .timeline_event_grades
                  .find_by(evaluation_criterion: evaluation_criterion_2)
                  .grade
                  .to_f
                  .to_s,
                nil
              ]
            ]
          },
          {
            title: 'Students',
            rows: [
              [
                'User ID',
                'Student ID',
                'Email Address',
                'Name',
                'Level',
                'Title',
                'Affiliation',
                'Tags',
                'Last Seen At',
                'Criterion A (2,3) - Average',
                'Criterion B (2,3) - Average'
              ],
              [
                student_1.user_id,
                report_link_formula(student_1),
                student_1.email,
                student_1.name,
                student_1.level.number,
                student_1.title,
                student_1.affiliation,
                'tag 1, tag 2',
                last_seen_at(student_1),
                student_1_reviewed_submission
                  .timeline_event_grades
                  .find_by(evaluation_criterion: evaluation_criterion_1)
                  .grade
                  .to_f
                  .to_s,
                student_1_reviewed_submission
                  .timeline_event_grades
                  .find_by(evaluation_criterion: evaluation_criterion_2)
                  .grade
                  .to_f
                  .to_s
              ],
              [
                student_3_access_ended.user_id,
                report_link_formula(student_3_access_ended),
                student_3_access_ended.email,
                student_3_access_ended.name,
                student_3_access_ended.level.number,
                student_3_access_ended.title,
                student_3_access_ended.affiliation,
                'tag 2',
                last_seen_at(student_3_access_ended),
                nil,
                nil
              ],
              [
                student_4_dropped_out.user_id,
                report_link_formula(student_4_dropped_out),
                student_4_dropped_out.email,
                student_4_dropped_out.name,
                student_4_dropped_out.level.number,
                student_4_dropped_out.title,
                student_4_dropped_out.affiliation,
                'tag 3',
                last_seen_at(student_4_dropped_out),
                nil,
                nil
              ]
            ]
          },
          {
            title: 'Submissions',
            rows: [
              [
                'Student Email / Target ID',
                "L1T#{target_l1_evaluated.id}",
                "L2T#{target_l2_evaluated.id}"
              ],
              [
                student_1.email,
                {
                  'value' =>
                    "#{submission_grading(student_1_reviewed_submission)};RP",
                  'style' => 'pending-grade'
                },
                { 'value' => 'RP', 'style' => 'pending-grade' }
              ],
              [
                student_3_access_ended.email,
                { 'value' => 'RP', 'style' => 'pending-grade' }
              ],
              [
                student_4_dropped_out.email,
                { 'value' => 'RP', 'style' => 'pending-grade' }
              ]
            ]
          }
        ]
      end

      it 'restricts data in the export' do
        subject.execute

        expect(JSON.parse(course_export.reload.json_data)).to be_an_object_like(
          restricted_data
        )
      end
    end
  end
end
