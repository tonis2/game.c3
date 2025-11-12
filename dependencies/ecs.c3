module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;
import std::core::builtin;

alias Vec2f @private = float[<2>];
alias Vec3f @private = float[<3>];
alias Vec4f @private = float[<4>];

enum GpuType : inline uint
{
    HOST_VISIBLE,
    DEVICE_ONLY,
    CPU_ONLY
}

interface Allocator
{
    fn usz total_size();
    fn void set_used_size(usz size);
    fn char* data();
    fn void upload(void* data, usz size, usz offset);
    fn ulong get_address();
    fn usz get_used_size();
    fn uint get_type();
    fn void* get_buffer();
    fn void free();
}

faultdef NO_KEY_FOUND, COMPONENT_BUFFER_OVERFLOW;

struct Component {
    uint id;
    uint size;
    uint buffer;
    usz used_size;
    usz offset;
    EntityManager* manager;
}

struct BufferView {
    uint component;
}

bitstruct Entity : ulong {
    uint id : 0..31;
    uint bitmask : 32..63;
}

bitstruct BufferID : ulong {
    uint component : 0..31;
    uint entity : 32..63;
}

alias ComponentMap = HashMap{String, Component};
alias ViewMap = HashMap{BufferID, BufferView};
alias UploadFN = fn void (Allocator buffer, void* data, usz data_size, usz offset);

fn usz alignUp(usz value, usz factor)  => value + factor - 1 - (value + factor - 1) % factor;

struct EntityManager {
    ComponentMap keys;
    ViewMap views;
    List{Component} components;
    List{Allocator} buffers;
    List{Entity} entities;
    UploadFN uploadFN;
}

fn EntityManager create_manager(Allocator[] buffers, UploadFN uploadFN = null) {
    EntityManager manager = {
        .uploadFN = uploadFN,
    };
    foreach (buffer: buffers) manager.buffers.push(buffer);
    return manager;
}

macro uint BufferID.hash(BufferID i) => builtin::@generic_hash((ulong)i);

fn void Component.reset(&self) => self.used_size = 0;

fn void EntityManager.free(&self) {
    // foreach (buffer: self.buffers) {
    //     buffer.free();
    // };
    self.buffers.free();
    self.keys.free();
    self.views.free();
    self.entities.free();
}

macro void EntityManager.@query(self, ...; @callback(Entity entity)) {
    foreach ENTITY: (entity: self.entities) {
        $for var $i = 0; $i < $vacount; $i++:
            if (!entity.has_name($vaarg[$i], self)) continue ENTITY;
        $endfor
        @callback(entity);
    }
}

fn bool Entity.has_name(self, String name, EntityManager manager) {
    Component? key = manager.keys[name];

    if (try key) {
        uint mask = 1 << key.id;
        return self.bitmask & mask == mask;
    }

    return false;
}

fn void EntityManager.create_view(&self, BufferID buffer, Component component) {
    self.views.set(buffer, {
        component.id, 
    });
}  

fn Component? EntityManager.new_component(&self, void* data = null, uint size = 0, uint buffer_index) {
    Allocator buffer = self.buffers[buffer_index];

    if (!(buffer.total_size() > buffer.get_used_size() + size)) return COMPONENT_BUFFER_OVERFLOW?;

    Component component = {
        .id = (uint)self.components.len(),
        .size = size,
        .buffer = buffer_index,
        .offset = buffer.get_used_size(),
        .manager = self
    };

    self.components.push(component);
 
    if (data != null) {
        if (buffer.get_type() == GpuType.DEVICE_ONLY) {
            self.uploadFN(buffer, data, size, component.offset);
        } else {
            buffer.upload(data, size, component.offset);
        }
    }

    buffer.set_used_size(buffer.get_used_size() + size);
    return component;
}

macro Component? EntityManager.@create_component(&self, #type = null, uint size = 0, void* data = null, int buffer_index = -1) {
    uint default_buffer = buffer_index >= 0 ? buffer_index : 0;
    //$typeof(#type).typeid.kindof == STRUCT &&& 
    if (size == 0 && data == null) {
        $if $typeof(#type).has_tagof("BUFFER"):
            default_buffer = $typeof(#type).tagof("BUFFER");
        $endif
        return self.new_component(&&#type, $typeof(#type).sizeof, default_buffer);
    } else {
        return self.new_component(data, size, default_buffer);
    }
}

macro Entity? EntityManager.@create_entity(&self, ...) {
    String type_name;
    Entity entity = {.id = (uint)self.entities.len()};

    uint size = 0;
    uint buffer_index = 0;
    uint type_id = 0;
    Component component;

    // Loop over entity data
    $for var $i = 0; $i < $vacount; $i++:
        buffer_index = 0;
        type_name = $typeof($vaarg[$i]).nameof;
        size += $typeof($vaarg[$i]).sizeof;

        $if $typeof($vaarg[$i]).has_tagof("BUFFER"):
            buffer_index = $typeof($vaarg[$i]).tagof("BUFFER");
        $endif

        $if $typeof($vaarg[$i]).nameof == "Component":
            // Todo: Component needs name
            component = $vaarg[$i];
        $else
            component = self.@create_component($vaarg[$i], buffer_index: buffer_index)!;
        $endif
    
        if (!self.keys.has_key(type_name)) {
            self.keys.set(type_name, { .id = (uint)self.keys.len(), .buffer = component.buffer });
        }
        
        type_id = self.keys[type_name]!!.id;
        entity.bitmask |= 1 << type_id;

        self.create_view(
            (BufferID) { .component = type_id, .entity = entity.id },
            component
        );

    $endfor

    self.entities.push(entity);
    return entity;
}

macro bool Entity.@has_type(self, #type, EntityManager manager) {
    Component? key = manager.keys[#type.nameof];

    if (try key) {
        uint mask = 1 << key.id;
        return self.bitmask & mask == mask;
    }

    return false;
}

<*
 @require ($kindof(#type) != OPTIONAL && $kindof(#type) != POINTER) : "Added type should not be optional or pointer"
*>
macro void? Entity.@add(&self, #type, EntityManager* manager, int buffer_index = -1) {
    String type_name = $typeof(#type).nameof;
    uint size = $typeof(#type).sizeof;

    Component component = manager.@create_component(#type, buffer_index: buffer_index)!;

    if (!manager.keys.has_key(type_name)) {
        manager.keys.set(type_name, 
        {
            .id = (uint)manager.keys.len(),
            .buffer = component.buffer,
        });
    }

    Entity* target = manager.entities.get_ref(self.id);
    uint type_id = manager.keys[type_name]!.id;
    target.bitmask |= 1 << type_id;

    manager.create_view(
        (BufferID) { .component = type_id, .entity = self.id },
        component
    );
}

fn void Entity.add_component(&self, String type_name, Component component, EntityManager manager) {
    if (!manager.keys.has_key(type_name)) {
        manager.keys[type_name] = {
            .id = (uint)manager.keys.len(),
            .buffer = component.buffer,
        };
    }

    self.bitmask |= 1 << manager.keys[type_name]!!.id;
    manager.entities[self.id].bitmask = self.bitmask;

    manager.create_view(
        (BufferID) { .component = manager.keys[type_name]!!.id, .entity = self.id },
        component
    );
}

fn uint get_size(Entity entity, EntityManager manager) {
    uint size;
    manager.views.@each(;BufferID key, BufferView view) {
        if (key.entity == entity.id) size += manager.components[view.component].size;
    };
 
    return size;
}

// macro Entity.@set_value(self, #type, #data, EntityManager manager, usz offset = 0) {
//     Component component = manager.keys[#type.nameof]!!;
//     BufferID index = {
//         .component = component.id,
//         .entity = self.id,
//     };

//     Allocator buffer = manager.buffers[component.buffer];
//     uint type_offset = manager.views[index]!!;

//     return buffer.upload(&&#data, $typeof(#data).sizeof, type_offset + offset);
// }


<*
 @require self.size > (self.used_size + size) : "Component total size is too small"
*>
macro void Component.@push(&self, #data, usz size = 0, usz offset = 0, bool auto_increase = true) {
    usz data_size = size;
    Allocator buffer = self.manager.buffers[self.buffer];
    usz data_offset = self.offset + offset + (self.used_size * (auto_increase ? 1 : 0));

    $if $kindof(#data) == POINTER: {
        if (size == 0) data_size = $typeof(*#data).sizeof;
    }
    $else {
        if (size == 0) data_size = $typeof(#data).sizeof;
    }   
    $endif

    $if $kindof(#data) == POINTER: {
        if (buffer.get_type() == GpuType.DEVICE_ONLY.ordinal) {
            self.manager.uploadFN(buffer, #data, data_size, data_offset);
        } else  {
            buffer.upload(#data, data_size, data_offset);
        }
    }
    $else {
        if (buffer.get_type() == GpuType.DEVICE_ONLY.ordinal) {
            self.manager.uploadFN(buffer, &&#data, data_size, data_offset);
        } else  {
            buffer.upload(&&#data, data_size, data_offset);
        }
    }
    $endif

    self.used_size += data_size;
}


<*
 @require ($typeof(#target).nameof == "Entity" || $typeof(#target).nameof == "Component") : "Target can only be compontent or entity"
*>
macro @upload(EntityManager manager, #target, #data, usz size = 0, usz offset = 0, bool update_size = false) {
    usz data_size = size;
    Allocator buffer;
    usz data_offset = 0;
    String type_name;

    $if $kindof(#data) == POINTER: {
        if (size == 0) data_size = $typeof(*#data).sizeof;
        type_name = $typeof(*#data).nameof;
    }
    $else {
        if (size == 0) data_size = $typeof(#data).sizeof;
        type_name = $typeof(#data).nameof;
    }   
    $endif

    $if $typeof(#target).nameof == "Component":
        buffer = manager.buffers[#target.buffer];
        data_offset = #target.offset + offset;
        
        // if (update_size) {
        //     Component* component = manager.components.get_ref(#target.id);
        //     component.used_size += size;
        // };
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component_info = manager.keys[type_name]!!;
        BufferID index = {
            .component = component_info.id,
            .entity = #target.id,
        };

        data_offset = (uint)manager.components[manager.views[index]!!.component].offset + offset;
        buffer = manager.buffers[component_info.buffer];

        // if (update_size) {
        //     Component* component = manager.components.get_ref(component_info.id);
        //     component.used_size += size;
        // };
    $endif;

    $if $kindof(#data) == POINTER: {
        if (buffer.get_type() == GpuType.DEVICE_ONLY.ordinal) {
            manager.uploadFN(buffer, #data, data_size, data_offset);
        } else  {
            buffer.upload(#data, data_size, data_offset);
        }
    }
    $else {
        if (buffer.get_type() == GpuType.DEVICE_ONLY.ordinal) {
            manager.uploadFN(buffer, &&#data, data_size, data_offset);
        } else  {
            buffer.upload(&&#data, data_size, data_offset);
        }
    }
    $endif
}


<*
 @require ($typeof(#target).nameof == "Entity" || $typeof(#target).nameof == "Component") : "Target can only be compontent or entity"
*>
macro @get(EntityManager manager, #target, #type, usz offset = 0) {
    usz $type_size = #type.sizeof;
    $if $typeof(#target).nameof == "Component":
        Allocator buffer = manager.buffers[#target.buffer];
        usz type_offset = #target.offset;
        return bitcast(*(char[$type_size]*)buffer.data()[type_offset..(type_offset + $type_size)], #type);
    $endif;
   
    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = (uint)manager.components[manager.views[index]!!.component].offset;
        return bitcast(*(char[$type_size]*)buffer.data()[type_offset..(type_offset + $type_size)], #type);
    $endif;
}

<*
 @require ($typeof(#target).nameof == "Entity" || $typeof(#target).nameof == "Component") : "Target can only be compontent or entity"
*>
macro @get_ref(EntityManager manager, #target, #type = null, usz offset = 0) {

    $if $typeof(#target).nameof == "Component":
        usz type_offset = #target.offset;
        return (void*)buffer.data() + type_offset;
    $endif;
   
    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        uint type_offset = (uint)manager.components[manager.views[index]!.component].offset;
        return (void*)manager.buffers[component.buffer].data() + type_offset;
    $endif;
}

fn void* Component.get_ref(&self) => (void*)self.manager.buffers[self.buffer].data() + self.offset;



// <*
//  @require self.size != 0 && self.used_size != 0 : `Component is empty`
// *>
// fn Node* Component.get(&self, usz index) @operator([]) @inline
// {
// 	return (void*)self.manager.buffers[self.buffer].data() + self.offset + (index * Node.sizeof);
// }

macro @get_address(EntityManager manager, #target, #type = null, usz offset = 0) {
    $if $typeof(#target).nameof == "Component":
        return manager.buffers[#target.buffer].get_address() + #target.offset + offset;
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = (uint)manager.components[manager.views[index]!!].offset;
        return manager.buffers[component.buffer].get_address() + type_offset + offset;
    $endif;
}

macro @get_offset(EntityManager manager, #target, String type = "") {
    $if $typeof(#target).nameof == "Component":
        return (uint)#target.offset;
    $endif;

    $if $typeof(#target).nameof == "Entity":
        if (type != "") {
            Component component = manager.keys[type]!;
            BufferID index = {
                .component = component.id,
                .entity = #target.id,
            };
            return (uint)manager.components[manager.views[index]!!.component].offset;
        }

        // 2240
        manager.views.@each(;BufferID id, BufferView view) {
            if (id.entity == #target.id) {
                Component component = manager.components[view.component];
                return (usz)component.offset;
            }
        };
    $endif;

    return NO_KEY_FOUND?;
}

struct Buffer (Allocator) {
    usz size;
    usz used_size;
    char* mapped;
}

fn void Buffer.push(&self, void* data, usz size) @dynamic {
    if (self.used_size + size > self.size) {
        self.ensure_size(self.used_size + size);
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
    } else {
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
    }
}

// usz size = alignUp(new_size, 256);
fn void Buffer.ensure_size(&self, usz new_size) @dynamic {
    new_size = alignUp(new_size, 16);
    if (self.used_size + new_size > self.size) {
        self.mapped = mem::realloc(self.mapped, new_size);
        self.size = new_size;
    }
}

fn void Buffer.upload(&self, void* data, usz size, usz offset) @dynamic {
    if (self.used_size + size > self.size) self.ensure_size(self.used_size + size);
    mem::copy(self.mapped + offset, data, size);
}

fn void Buffer.free(&self) @dynamic {
    mem::free(self.mapped);
    self.size = 0;
    self.used_size = 0;
}

fn char* Buffer.data(&self) @dynamic => self.mapped;
fn usz Buffer.total_size(&self) @dynamic => uint.max;
fn usz Buffer.get_used_size(&self) @dynamic => self.used_size;
fn ulong Buffer.get_address(&self) @dynamic => 0;
fn uint Buffer.get_type(&self) @dynamic => 2;
fn void* Buffer.get_buffer(&self) @dynamic => null;
fn void Buffer.set_used_size(&self, usz size) @dynamic {
    self.ensure_size(size);
    self.used_size = size;
}

module ecs @if($feature(ECS_EXTRA));
import gltf;
import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::time;
import collision;
import c3w;

struct Node {
    bool dirty;
    int parent;
    Vec3f translation;
    Vec3f scale;
    Quaternionf rotation;
    Matrix4f matrix;
}

alias NodeComponent = Component;

<*
 @require self.size != 0 && self.used_size != 0 : `Component is empty`
*>
fn Node* NodeComponent.get(&self, usz index) @operator([]) @inline
{
	return (void*)self.manager.buffers[self.buffer].data() + self.offset + (index * Node.sizeof);
}

<*
 @require self.size != 0 && index * Node.sizeof <= self.size : `Component is not big enough`
*>
fn void NodeComponent.set(&self, usz index, Matrix4f matrix) @inline
{
    @upload(*self.manager, *self, matrix, size: Matrix4f.sizeof, offset: self.offset + (index * Node.sizeof));
}

<*
 @require self.size != 0 : `Component is empty`
*>
fn Matrix4f NodeComponent.global_matrix(&self, uint index) @inline
{
    Node* current_node = self.get(index);
    Matrix4f global_matrix = gltf::to_matrix(current_node.translation, current_node.scale, current_node.rotation);

    while (current_node.parent != - 1) {
        Node* parent_node = self.get(current_node.parent);
        global_matrix = gltf::to_matrix(parent_node.translation, parent_node.scale, parent_node.rotation) * global_matrix;
        current_node = parent_node;
    }
    
    return global_matrix;
}

<*
 @require self.size != 0 : `Component is empty`
*>
fn void NodeComponent.recalculate(&self, bool loop = false) @inline
{
    for LOOP: (uint i = 0; i < self.size / Node.sizeof; i++) {
        Node* node = self.get(i);

        if (node.dirty == true) {
            Matrix4f global_matrix = gltf::to_matrix(node.translation, node.scale, node.rotation);
            Node* parent_node = node.parent > -1 ? self.get(node.parent) : null;

            while (parent_node != null) {
                global_matrix = gltf::to_matrix(parent_node.translation, parent_node.scale, parent_node.rotation) * global_matrix;
                parent_node = parent_node.parent > -1 ? self.get(parent_node.parent) : null;
            }

            node.matrix = global_matrix;
            node.dirty = false;
        }
    }
}

struct Position @private {
    Vec3f scale;
    Vec3f translation;
}

struct Velocity @tag("BUFFER", 0) @private {
    float x;
    float y;
    float z;
}

fn void test_ecs() @test {
    Buffer buffer;
    defer buffer.free();

    EntityManager manager = create_manager({
        &buffer,
    });

    defer manager.free();

    Component velocity_comp = manager.@create_component((Velocity){ 1.0, 2.0, 3.0 })!!;
    Component animation_comp = manager.@create_component(size: Position.sizeof)!!;
    
    ecs::@upload(manager, velocity_comp, (Velocity){ 3.0, 3.0, 3.0 });
 
    Entity player = manager.@create_entity(
        (Position) {
            .translation = {1.0, 1.0, 1.0},
            .scale = {1.0, 1.0, 1.0}
        },
    )!!;

    Entity player2 = manager.@create_entity(
        (Position){},
        velocity_comp,
    )!!;

    player.add_component("Velocity", velocity_comp, manager);
    // player2.add("Animation", animation_comp, manager);

    @upload(manager, animation_comp, &&(Position) {
        .scale = {5.0, 5.0, 5.0},
        .translation = {5.0, 5.0, 5.0},
    }, size: Position.sizeof);
    
    assert(@get_offset(manager, player, "Position")!! == Velocity.sizeof + Position.sizeof);
    assert(@get_offset(manager, player2, "Position")!! == Velocity.sizeof + Position.sizeof * 2);
    assert(@get(manager, animation_comp, Position).scale == (Vec3f) {5.0, 5.0, 5.0});


    Velocity* velocity_ptr = @get_ref(manager, player, Velocity);
    velocity_ptr.x = 5.00;

    manager.@query("Position", "Velocity"; Entity entity) {
        Velocity velocity = @get(manager, entity, Velocity);
        io::printfn("QUERY ENTRY");

        assert(velocity.x == 5.000000);
        assert(velocity.y == 3.000000);

        @upload(manager, entity, (Position) {
            .translation = {5.0, 5.0, 5.0},
            .scale = {5.0, 5.0, 5.0}
        });

        Position position = @get(manager, entity, Position);
        assert(position.translation.x == 5.000000);
    };
}

