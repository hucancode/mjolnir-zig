import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

def draw_square_pyramid(ax, position, rotation, base_size=0.1, height=0.2):
    base_center = np.array(position)
    z_offset = np.array([0, 0, height])
    
    # Base vertices of a square in the XY plane
    base_vertices = np.array([
        [-base_size, -base_size, 0],
        [ base_size, -base_size, 0],
        [ base_size,  base_size, 0],
        [-base_size,  base_size, 0]
    ])
    
    # Rotate base and compute apex
    R = rotation
    rotated_base_vertices = np.dot(base_vertices, R.T) + base_center
    apex = base_center + np.dot(z_offset, R.T)
    
    vertices = np.vstack([rotated_base_vertices, apex])
    
    faces = [
        [vertices[0], vertices[1], vertices[4]],
        [vertices[1], vertices[2], vertices[4]],
        [vertices[2], vertices[3], vertices[4]],
        [vertices[3], vertices[0], vertices[4]],
        [vertices[0], vertices[1], vertices[2], vertices[3]]
    ]
    
    pyramid = Poly3DCollection(faces, alpha=.5, linewidths=1, edgecolors='k', facecolor='cyan')
    ax.add_collection3d(pyramid)

def quaternion_to_rotation_matrix(q):
    w, x, y, z = q
    return np.array([
        [1 - 2*y**2 - 2*z**2, 2*x*y - 2*z*w,     2*x*z + 2*y*w],
        [2*x*y + 2*z*w,     1 - 2*x**2 - 2*z**2, 2*y*z - 2*x*w],
        [2*x*z - 2*y*w,     2*y*z + 2*x*w,     1 - 2*x**2 - 2*y**2]
    ])

# Setup plot
fig = plt.figure()
ax = fig.add_subplot(111, projection='3d')
ax.set_box_aspect([1, 1, 1])

# Bone data
bones_data = [
    ((0.00000000000008440351, 0.000000000000000000000000000014965666, 0.00000011920929), (0.000000009157396, -0.000000024203244, 0.0000000000000008865547, 0)),
    ((-0.000000000000018485984, -2.5, 0.0000003565728), (0.00000000021100277, -0.0000000000000053290705, 0.0000000000000002318526,0)),
    ((-0.00000000000021809006, -2.5, 0.0000007099429), (0.00000012145742, -0.000000073510044, -0.39690524, 0)),
    ((1.1285541, -2.7692232, 0.0000011836073), (0.00000011667257, 0.00000012777278, -0.599056, 0)),
]

# Draw pyramids
for pos, quat in bones_data:
    rot = quaternion_to_rotation_matrix(quat)
    draw_square_pyramid(ax, pos, rot)

# Expand limits
ax.set_xlim([-2.5, 2.5])
ax.set_ylim([-6.0, 6.0])  # Your bones are around y = 2.5
ax.set_zlim([-2.5, 2.5])
ax.set_xlabel("X")
ax.set_ylabel("Y")
ax.set_zlabel("Z")
plt.tight_layout()
plt.show()
