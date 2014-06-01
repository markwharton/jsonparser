# /usr/bin/bash
# http://superuser.com/questions/61185/why-do-i-get-files-like-foo-in-my-tarball-on-os-x

dir="$1"

rmvattr() {
	cd "$1"
	echo "Entering $1"
	for d in *; do
		if [ -d "$d" ]; then
			(rmvattr "$d")
		else
			encs=$(xattr "$d")
			for enc in $encs; do
				xattr -d "$enc" "$d"
			done
		fi
	done
}

(rmvattr "$dir")
