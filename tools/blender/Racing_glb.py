# Blender operator preset "Racing glb" for export_scene.gltf (Blender 5.x).
# Install for GUI use: copy to <blender config>/scripts/presets/operator/export_scene.gltf/Racing glb.py
# Headless scripts load it through tools/blender/racing_export.py so the options live in one place.
import bpy
op = bpy.context.active_operator

op.export_format = 'GLB'
op.export_yup = True
op.export_apply = True            # apply modifiers
op.export_texcoords = True
op.export_normals = True
op.export_tangents = True
op.export_vertex_color = 'MATERIAL'
op.export_materials = 'EXPORT'
op.export_image_format = 'AUTO'
op.export_extras = True           # custom properties (wheel_radius, ...)
op.export_cameras = False
op.export_lights = False
op.export_animations = False      # static assets; set True for files with actions
op.use_selection = False
op.export_skins = True
op.export_morph = True
