<?php
/*post format-Unterstützung entfernen*/
function remove_post_formats() {
			remove_theme_support('post-formats');
			}

add_action ('after_setup_theme', 'remove_post_formats', 11);?>
<?php
/*entry-metas mit in die content.php holen*/
function get_entry_meta() {
    $categories_list = get_the_category_list( __( ', ', 'twentytwelve' ) );
    $tag_list = get_the_tag_list( '', __( ', ', 'twentytwelve' ) );
    $date = array(
        esc_url( get_permalink() ),
        esc_attr( get_the_time() ),
        esc_attr( get_the_date( 'c' ) ),
        esc_html( get_the_date() )
    );
    $author = array(
        esc_url( get_author_posts_url( get_the_author_meta( 'ID' ) ) ),
        esc_attr( sprintf( __( 'View all posts by %s', 'twentytwelve' ), get_the_author() ) ),
        get_the_author()
    );
    return array($categories_list, $tag_list, $date, $author);
}?>
