# Tracks an asynchronous scene build (AI generation, or a magenta-marked upload
# going through slot detection): its state, what was asked for, and what
# detection found. A template is created BEFORE its base image exists so the
# admin page has something to show while the job runs.
# See .claude-notes/scene-engine.md → "AI scenes and magenta detection".
class AddGenerationToSceneTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :scene_templates, :generation, :jsonb, null: false, default: {}
  end
end
